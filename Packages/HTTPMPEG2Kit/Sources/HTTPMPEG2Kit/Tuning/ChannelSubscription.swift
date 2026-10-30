import Foundation

/// A lease on one channel's transport stream, handed out by `TunerBroker`. Subscribers read `chunks` and never see
/// a URL; `cancel()` gives the lease back, and the tuner is freed once no subscriber of that upstream remains.
///
/// `chunks` finishes normally when the device ends the stream, throws the mapped `HDHomeRunClientError` when it
/// fails mid-way (`.connectionLost`, for example), and throws `.cancelled` when the subscription is cancelled or a
/// newer subscription of the same slot replaced it. A subscriber that falls more than its queue's bound behind
/// loses the oldest chunks and reads one `.discontinuity` before the data that follows the gap.
public nonisolated final class ChannelSubscription: Sendable {
    public let chunks: AsyncThrowingStream<TSChunk, any Error>
    /// This subscriber's channel, device and tuner. On a multiplex upstream `programNumber` and `frequency` are set.
    public var route: StreamRoute { queue.route }
    /// The program to select from the PAT; set when the upstream is a full multiplex.
    public var programNumber: Int? { route.programNumber }

    let fanout: UpstreamFanout
    private let queue: SubscriberQueue
    private let id: UInt64

    init(chunks: AsyncThrowingStream<TSChunk, any Error>, queue: SubscriberQueue, fanout: UpstreamFanout,
         id: UInt64) {
        self.chunks = chunks
        self.queue = queue
        self.fanout = fanout
        self.id = id
    }

    /// Leaves the stream at once; the last subscriber to leave closes the upstream, which frees the tuner. Safe to
    /// call repeatedly and from any thread.
    public func cancel() {
        fanout.remove(id, reason: .cancelled)
    }

    /// True once the subscription ended for any reason.
    public var isEnded: Bool {
        !fanout.contains(id)
    }

    /// How many times this subscriber fell behind and lost data (each delivered one `.discontinuity`), for the
    /// local debug overlay.
    public var discontinuityCount: Int { queue.discontinuities }

    /// Bytes this subscriber lost by falling behind.
    public var droppedByteCount: Int { queue.droppedBytes }

    /// Ends this subscription with `reason` (the broker replacing it, for example).
    func end(_ reason: TunerReleaseReason) {
        fanout.remove(id, reason: reason)
    }
}
