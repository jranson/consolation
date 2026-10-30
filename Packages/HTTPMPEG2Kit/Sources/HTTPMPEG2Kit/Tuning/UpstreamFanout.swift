import Foundation
import Synchronization

/// One upstream connection (one tuner) shared by every subscriber of its channel, or of its multiplex.
///
/// The reader copies each chunk into every subscriber's `SubscriberQueue` and never waits for one. The app's own
/// subscribers get a bounded queue (overflow drops the oldest chunks and marks a `.discontinuity`); relay clients
/// get an unbounded one and enforce their own bound while they drain it (a slow one is disconnected).
/// The upstream closes when the last subscriber leaves, or ends every subscription when the device ends or breaks
/// the stream. Either way `onEnd` runs exactly once.
nonisolated final class UpstreamFanout: Sendable {
    /// The route of the channel that opened the upstream. For a multiplex, `frequency` is set.
    let route: StreamRoute

    private struct State {
        var subscribers: [UInt64: SubscriberQueue] = [:]
        var nextID: UInt64 = 0
        var forwarder: Task<Void, Never>?
        var isEnded = false
        /// When the upstream opened or last delivered bytes.
        var lastActivity: ContinuousClock.Instant
    }

    private let upstream: any TunerStream
    private let onEnd: @Sendable (TunerReleaseReason) -> Void
    private let state: Mutex<State>

    init(route: StreamRoute, upstream: any TunerStream, onEnd: @escaping @Sendable (TunerReleaseReason) -> Void) {
        self.route = route
        self.upstream = upstream
        self.onEnd = onEnd
        state = Mutex(State(lastActivity: ContinuousClock.now))
    }

    var isEnded: Bool {
        state.withLock { $0.isEnded }
    }

    var subscriberCount: Int {
        state.withLock { $0.subscribers.count }
    }

    /// Subscribers reading `channel` (on a multiplex, each channel is one program).
    func subscriberCount(of channel: ChannelKey) -> Int {
        state.withLock { state in state.subscribers.values.filter { $0.route.channel == channel }.count }
    }

    /// The channels the subscribers read, each once.
    var channels: Set<ChannelKey> {
        state.withLock { state in Set(state.subscribers.values.map(\.route.channel)) }
    }

    func contains(_ id: UInt64) -> Bool {
        state.withLock { $0.subscribers[id] != nil }
    }

    /// Whether the upstream is open and delivered bytes (or opened) within `maxSilence`. A quieter upstream is
    /// stalled, and new subscribers should not join it.
    func isFresh(within maxSilence: Duration) -> Bool {
        state.withLock { !$0.isEnded && ContinuousClock.now - $0.lastActivity <= maxSilence }
    }

    /// Adds a subscriber that sees `route` (the upstream's own by default) and keeps at most `byteLimit` bytes
    /// waiting (nil: no bound). On an upstream that already ended, the subscription comes back ended.
    func subscribe(route: StreamRoute? = nil, byteLimit: Int? = nil) -> ChannelSubscription {
        let queue = SubscriberQueue(route: route ?? self.route, byteLimit: byteLimit)
        let id = state.withLock { state in
            defer { state.nextID &+= 1 }
            guard !state.isEnded else { return state.nextID }
            state.subscribers[state.nextID] = queue
            return state.nextID
        }
        let added = contains(id)
        // The consumer stopped reading (its task was cancelled) or dropped the stream unread.
        let leave: @Sendable () -> Void = { [weak self] in self?.remove(id, reason: .cancelled) }
        let release = SubscriberReleaseGuard(leave)
        let chunks = AsyncThrowingStream<TSChunk, any Error> {
            _ = release
            return try await queue.next(onAbandon: leave)
        }
        if !added { queue.finish(throwing: HDHomeRunClientError.cancelled) }
        return ChannelSubscription(chunks: chunks, queue: queue, fanout: self, id: id)
    }

    /// Starts copying the upstream's bytes to the subscribers, off every actor.
    func start() {
        let task = Task.detached(priority: .userInitiated) { [weak self, upstream] in
            do {
                for try await data in upstream.chunks {
                    guard let self else { return }
                    self.deliver(data)
                }
                self?.end(.ended)
            } catch {
                let mapped = HDHomeRunClientError(transportError: error, host: "")
                self?.end(mapped == .cancelled ? .cancelled : .failed(mapped))
            }
        }
        let alreadyEnded = state.withLock { state in
            state.forwarder = task
            return state.isEnded
        }
        if alreadyEnded { task.cancel() }
    }

    private struct Removal {
        let queue: SubscriberQueue
        /// Set when the last subscriber left: the forwarder to stop, before the upstream closes.
        let closing: Task<Void, Never>??
    }

    /// Removes one subscriber; the last one out closes the upstream with the same reason.
    func remove(_ id: UInt64, reason: TunerReleaseReason) {
        let removal: Removal? = state.withLock { state in
            guard let queue = state.subscribers.removeValue(forKey: id) else { return nil }
            guard state.subscribers.isEmpty, !state.isEnded else {
                return Removal(queue: queue, closing: nil)
            }
            state.isEnded = true
            return Removal(queue: queue, closing: .some(state.forwarder))
        }
        guard let removal else { return }
        Self.finish(removal.queue, reason: reason)
        guard case .some(let forwarder) = removal.closing else { return }
        forwarder?.cancel()
        upstream.cancel()
        onEnd(reason)
    }

    /// Closes the upstream and ends every subscription once.
    func end(_ reason: TunerReleaseReason) {
        let ending: (subscribers: [SubscriberQueue], forwarder: Task<Void, Never>?)? = state.withLock { state in
            guard !state.isEnded else { return nil }
            state.isEnded = true
            let subscribers = Array(state.subscribers.values)
            state.subscribers = [:]
            return (subscribers, state.forwarder)
        }
        guard let ending else { return }
        ending.forwarder?.cancel()
        upstream.cancel()
        for queue in ending.subscribers { Self.finish(queue, reason: reason) }
        onEnd(reason)
    }

    private func deliver(_ data: Data) {
        let subscribers = state.withLock { state in
            state.lastActivity = ContinuousClock.now
            return Array(state.subscribers.values)
        }
        for queue in subscribers { queue.push(data) }
    }

    private static func finish(_ queue: SubscriberQueue, reason: TunerReleaseReason) {
        switch reason {
        case .ended: queue.finish()
        case .failed(let error): queue.finish(throwing: error)
        case .cancelled, .replaced: queue.finish(throwing: HDHomeRunClientError.cancelled, discardingBacklog: true)
        }
    }
}
