import Foundation
import Synchronization

/// One subscriber's backlog between an upstream's reader and the subscriber's task.
///
/// The reader pushes and never waits. With a `byteLimit`, an overflow drops the oldest chunks and puts one
/// `.discontinuity` in front of the data that is left, so the subscriber's demuxer resynchronizes instead of
/// reading spliced bytes as one stream. Without a limit (relay clients, which enforce their own bound and are
/// disconnected when they fall behind) nothing is dropped.
nonisolated final class SubscriberQueue: Sendable {
    private enum Terminal {
        case finished
        case failed(any Error)
    }

    private struct State {
        var items: [TSChunk] = []
        var head = 0
        var bytes = 0
        var waiter: CheckedContinuation<TSChunk?, any Error>?
        var terminal: Terminal?
        /// The consumer's task was cancelled: every later `next()` returns nil.
        var isAbandoned = false
        var discontinuities = 0
        var droppedBytes = 0

        mutating func popFirst() -> TSChunk? {
            guard head < items.count else { return nil }
            let item = items[head]
            head += 1
            switch item {
            case .data(let data): bytes -= data.count
            case .discontinuity: discontinuities += 1
            }
            if head == items.count {
                items.removeAll(keepingCapacity: true)
                head = 0
            } else if head >= 64, head * 2 >= items.count {
                items.removeFirst(head)
                head = 0
            }
            return item
        }

        /// Drops the oldest data until the backlog fits `limit` (always keeping the newest chunk), then makes sure a
        /// `.discontinuity` leads what is left.
        mutating func trim(to limit: Int) {
            guard bytes > limit else { return }
            var dropped = false
            while bytes > limit, items.count - head > 1 {
                if case .data(let data) = items[head] {
                    bytes -= data.count
                    droppedBytes += data.count
                    dropped = true
                }
                head += 1
            }
            guard dropped else { return }
            if head > 0 {
                head -= 1
                items[head] = .discontinuity
            } else {
                items.insert(.discontinuity, at: 0)
            }
        }
    }

    /// The most bytes kept waiting for the subscriber, or nil for no bound.
    let byteLimit: Int?
    /// The route this subscriber sees (a multiplex subscriber's own channel and program).
    let route: StreamRoute
    private let state = Mutex(State())

    init(route: StreamRoute, byteLimit: Int?) {
        self.route = route
        self.byteLimit = byteLimit
    }

    /// How many `.discontinuity` markers the subscriber has read: how often it fell behind and lost data.
    var discontinuities: Int { state.withLock { $0.discontinuities } }
    var droppedBytes: Int { state.withLock { $0.droppedBytes } }
    var queuedBytes: Int { state.withLock { $0.bytes } }

    /// Reader side: adds a chunk. Never waits.
    func push(_ data: Data) {
        let waiter: CheckedContinuation<TSChunk?, any Error>? = state.withLock { state in
            guard state.terminal == nil, !state.isAbandoned else { return nil }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            state.items.append(.data(data))
            state.bytes += data.count
            if let byteLimit { state.trim(to: byteLimit) }
            return nil
        }
        waiter?.resume(returning: .data(data))
    }

    /// Ends the queue. `discardingBacklog` drops what the subscriber hasn't read (a cancelled or replaced
    /// subscription); otherwise the backlog is delivered first, then the end or the error.
    func finish(throwing error: (any Error)? = nil, discardingBacklog: Bool = false) {
        let waiter: CheckedContinuation<TSChunk?, any Error>? = state.withLock { state in
            guard state.terminal == nil else { return nil }
            state.terminal = error.map(Terminal.failed) ?? .finished
            if discardingBacklog {
                state.items.removeAll()
                state.head = 0
                state.bytes = 0
            }
            defer { state.waiter = nil }
            return state.waiter
        }
        guard let waiter else { return }
        if let error { waiter.resume(throwing: error) } else { waiter.resume(returning: nil) }
    }

    /// Consumer side: the next chunk, nil at the end, or the upstream's error. Cancelling the calling task returns
    /// nil and calls `onAbandon` once.
    func next(onAbandon: @escaping @Sendable () -> Void) async throws -> TSChunk? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<TSChunk?, any Error>) in
                let ready: Result<TSChunk?, any Error>? = state.withLock { state in
                    if let item = state.popFirst() { return .success(item) }
                    if state.isAbandoned { return .success(nil) }
                    switch state.terminal {
                    case .finished?:
                        return .success(nil)
                    case .failed(let error)?:
                        state.terminal = .finished
                        return .failure(error)
                    case nil:
                        state.waiter = waiter
                        return nil
                    }
                }
                if let ready { waiter.resume(with: ready) }
            }
        } onCancel: {
            let waiter: CheckedContinuation<TSChunk?, any Error>?? = state.withLock { state in
                guard !state.isAbandoned else { return nil }
                state.isAbandoned = true
                defer { state.waiter = nil }
                return .some(state.waiter)
            }
            guard case .some(let pending) = waiter else { return }
            pending?.resume(returning: nil)
            onAbandon()
        }
    }
}

/// Calls `onRelease` when the last reference to a subscription's byte stream goes away, so a subscriber that drops
/// its stream without reading it gives its place back.
nonisolated final class SubscriberReleaseGuard: Sendable {
    private let onRelease: @Sendable () -> Void

    init(_ onRelease: @escaping @Sendable () -> Void) {
        self.onRelease = onRelease
    }

    deinit {
        onRelease()
    }
}
