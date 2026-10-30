import Foundation
import Network

/// One client of `StreamRelayServer`: reads the request head, then answers or streams a subscription's bytes until
/// either side ends. The client is dropped as soon as its unsent backlog passes `maxQueuedBytes`.
nonisolated final class RelayConnection: @unchecked Sendable {
    // @unchecked: every mutable property is only touched on `queue`.
    let id: UInt64
    /// Set by the server when the request was a stream; it counts against the client limit.
    var isStreaming = false

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let maxQueuedBytes: Int
    private weak var server: StreamRelayServer?
    private var head = Data()
    private var hasRequest = false
    private var subscription: ChannelSubscription?
    private var writer: Task<Void, Never>?
    private var queuedBytes = 0
    private var isClosed = false

    init(id: UInt64, connection: NWConnection, queue: DispatchQueue, server: StreamRelayServer,
         maxQueuedBytes: Int) {
        self.id = id
        self.connection = connection
        self.queue = queue
        self.server = server
        self.maxQueuedBytes = maxQueuedBytes
    }

    func start(timeout: Duration) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        receiveHead()
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, !hasRequest else { return }
            close()
        }
    }

    /// Answers and closes.
    func respond(_ status: RelayResponseStatus, contentType: String? = nil, body: Data = Data()) {
        guard !isClosed else { return }
        hasRequest = true
        let response = status.head(contentType: contentType, contentLength: body.count) + body
        connection.send(content: response, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    /// Streams `subscription` to the client.
    func begin(_ subscription: ChannelSubscription) {
        guard !isClosed else {
            subscription.cancel()
            return
        }
        self.subscription = subscription
        connection.send(content: RelayResponseStatus.success.head(contentType: "video/mpeg"),
                        completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
        watchForHangUp()
        writer = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                for try await chunk in subscription.chunks {
                    guard case .data(let data) = chunk else { continue }
                    guard let self else { return }
                    self.enqueue(data)
                }
            } catch {}
            guard let relay = self else { return }
            relay.queue.async { relay.finishStream() }
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        writer?.cancel()
        subscription?.cancel()
        connection.cancel()
        server?.connectionClosed(self)
    }

    // MARK: - Private (on `queue`, except `enqueue`)

    private func receiveHead() {
        let most = RelayRequest.maxHeadBytes
        connection.receive(minimumIncompleteLength: 1, maximumLength: most) { [weak self] data, _, isDone, error in
            guard let self, !isClosed else { return }
            if let data { head.append(data) }
            switch RelayRequest.parse(head) {
            case .incomplete:
                if isDone || error != nil { close() } else { receiveHead() }
            case .rejected(let status):
                respond(status)
            case .request(let request):
                hasRequest = true
                head = Data()
                server?.handle(request, from: self)
            }
        }
    }

    /// Notices the client hanging up, which ends its subscription (and frees the tuner if nobody else watches).
    private func watchForHangUp() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_024) { [weak self] _, _, isDone, error in
            guard let self, !isClosed else { return }
            if isDone || error != nil { close() } else { watchForHangUp() }
        }
    }

    /// Called from the writer task: queues one chunk, or drops the client when its backlog is too large.
    private func enqueue(_ data: Data) {
        queue.async { [self] in
            guard !isClosed else { return }
            guard queuedBytes + data.count <= maxQueuedBytes else {
                close()
                return
            }
            queuedBytes += data.count
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                queuedBytes -= data.count
                if error != nil { close() }
            })
        }
    }

    /// The upstream ended: let the queued bytes go out, then close.
    private func finishStream() {
        guard !isClosed else { return }
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in self?.close() })
    }
}
