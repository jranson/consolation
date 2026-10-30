import Foundation

/// Settings for `TunerBroker`. Nothing here names the app.
public nonisolated struct TunerBrokerConfiguration: Sendable, Hashable {
    /// Request settings for the stream GETs.
    public var client: TunerClientConfiguration
    /// After we close our own stream the device needs about a second to free the tuner, so an 805 that arrives
    /// within `busyRetryWindow` of one of our releases is retried once after `busyRetryDelay`.
    public var busyRetryDelay: Duration
    public var busyRetryWindow: Duration
    /// "Keep N tuners free for others", the starting value (`TunerBroker.setReserve(_:)` changes it). Limits tiles
    /// and background work, never the stream the user starts.
    public var reserve: Int
    /// The starting multiplex policy (`TunerBroker.setMultiplexPolicy(_:)` changes it).
    public var multiplexPolicy: MultiplexPolicy
    /// How old a cached `status.json` may be before a free-tuner check fetches it again.
    public var statusMaxAge: Duration
    /// How long an open upstream may go without bytes and still take new subscribers. A quieter upstream counts as
    /// stalled: the next subscribe re-tunes instead of joining it, and relay attaches are refused.
    public var attachMaxSilence: Duration
    /// The most bytes one of the app's own subscriptions keeps waiting (about 2 s of a 19.4 Mbps multiplex). Past
    /// it the oldest chunks are dropped and the subscriber reads a `.discontinuity`. Relay clients have their own
    /// bound in `StreamRelayServerConfiguration`.
    public var subscriberQueueBytes: Int
    /// After an upstream on a device fails mid-stream, that device goes to the back of the route order for this
    /// long, so the engine's reconnect tries another device that carries the channel first.
    public var failedDevicePenalty: Duration

    public init(
        client: TunerClientConfiguration = TunerClientConfiguration(),
        busyRetryDelay: Duration = .seconds(1),
        busyRetryWindow: Duration = .milliseconds(1500),
        reserve: Int = 1,
        multiplexPolicy: MultiplexPolicy = .whenTunersAreShort,
        statusMaxAge: Duration = .seconds(1),
        attachMaxSilence: Duration = .seconds(3),
        subscriberQueueBytes: Int = 5_000_000,
        failedDevicePenalty: Duration = .seconds(10)
    ) {
        self.client = client
        self.busyRetryDelay = busyRetryDelay
        self.busyRetryWindow = busyRetryWindow
        self.reserve = reserve
        self.multiplexPolicy = multiplexPolicy
        self.statusMaxAge = statusMaxAge
        self.attachMaxSilence = attachMaxSilence
        self.subscriberQueueBytes = subscriberQueueBytes
        self.failedDevicePenalty = failedDevicePenalty
    }
}
