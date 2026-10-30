import Foundation

/// The single owner of every upstream tuner connection in the process. Players subscribe to channels and get a
/// `ChannelSubscription`, never a URL.
///
/// Upstreams are reference-counted: a program upstream (one channel) or a multiplex upstream (one RF frequency on
/// one device, several channels) is shared by every subscriber that reads it, and the last one to leave closes it
/// at once.
///
/// - `subscribe(_:slot:)` is for the app's own players: the single-view `.player` and one `.tile(id)` per
///   multi-view tile. Each slot replaces its own previous subscription first (close before open), and an older
///   subscribe of that slot still waiting for its response is abandoned, so a reconnect or a channel flip never
///   holds an extra tuner. Slots are independent. A channel that is already open, or whose multiplex is, is joined
///   at zero tuner cost.
/// - `attach(to:)` adds a subscriber (a relay client on another device) to a program upstream that is already
///   open. It never tunes.
/// - Upstreams that no slot reads (kept only for relay clients) never stand in the way of the local user. When a
///   slot tunes they stay only if `status.json` shows a free tuner; otherwise, and whenever the device still answers
///   805, they close first and their clients fail over to their own tuners.
public actor TunerBroker {
    public typealias StreamFactory = @Sendable (URL) -> any TunerStream
    public typealias StatusFetcher = @Sendable (DeviceChannelRef) async throws(HDHomeRunClientError) -> [TunerStatus]

    enum UpstreamKey: Hashable, Sendable {
        case program(ChannelKey)
        case multiplex(device: String, frequency: Int)
    }

    struct Upstream {
        let token: UInt64
        let key: UpstreamKey
        let fanout: UpstreamFanout
        let deviceKey: String
        /// The RF frequency, when the lineup gave it (program upstreams too, for the re-tune offer).
        let frequency: Int?
    }

    struct SlotState {
        /// Changes with every subscribe of the slot; an older subscribe that finds another value gives up.
        let token: UInt64
        var subscription: ChannelSubscription?
        var pending: (any TunerStream)?
    }

    /// An upstream being opened. Other slots that want it wait and then join instead of taking a second tuner.
    struct Opening {
        let slot: SubscriberSlot
        let token: UInt64
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    /// A tuner one of our upstreams held until this subscribe released it.
    struct ReleasedTuner {
        let deviceKey: String
        let tunerIndex: Int?
    }

    /// Opened and closed upstreams, for the app's tuner panel and relay. Buffers only the newest events.
    public nonisolated let events: AsyncStream<TunerEvent>
    let eventSink: AsyncStream<TunerEvent>.Continuation
    let configuration: TunerBrokerConfiguration
    let makeStream: StreamFactory
    let fetchStatus: StatusFetcher?
    let clock = ContinuousClock()

    /// "Keep N tuners free for others": tiles need 1 + reserve free tuners, background work 2 + reserve.
    public private(set) var reserve: Int
    public private(set) var multiplexPolicy: MultiplexPolicy

    var tokenCounter: UInt64 = 0
    var upstreamCount: UInt64 = 0
    var upstreams: [UpstreamKey: Upstream] = [:]
    var slots: [SubscriberSlot: SlotState] = [:]
    var opening: [UpstreamKey: Opening] = [:]
    var lastRelease: ContinuousClock.Instant?
    var statusCache: [String: (fetched: ContinuousClock.Instant, statuses: [TunerStatus])] = [:]
    /// Devices whose upstream failed mid-stream recently; they go last in the route order for a while.
    var recentFailures: [String: ContinuousClock.Instant] = [:]

    /// - Parameters:
    ///   - makeStream: builds one upstream connection; defaults to `HDHomeRunStreamClient`.
    ///   - fetchStatus: reads a device's `status.json` for the free-tuner checks (tiles, background work, keeping
    ///     relay-only upstreams), device choice and multiplex tuner choice. Without it those checks assume no tuner
    ///     is free, routes keep their order and every channel opens as a program stream.
    public init(
        configuration: TunerBrokerConfiguration = TunerBrokerConfiguration(),
        makeStream: StreamFactory? = nil,
        fetchStatus: StatusFetcher? = nil
    ) {
        let client = configuration.client
        self.configuration = configuration
        self.makeStream = makeStream ?? { HDHomeRunStreamClient(url: $0, configuration: client) }
        self.fetchStatus = fetchStatus
        reserve = max(configuration.reserve, 0)
        multiplexPolicy = configuration.multiplexPolicy
        (events, eventSink) = AsyncStream.makeStream(of: TunerEvent.self, bufferingPolicy: .bufferingNewest(32))
    }

    // MARK: - Settings

    /// "Keep N tuners free for others" (default 1). Applies to the next tile, background job and admission check;
    /// open streams are never closed by it, and the stream the user starts is never blocked by it.
    public func setReserve(_ count: Int) {
        reserve = max(count, 0)
    }

    public func setMultiplexPolicy(_ policy: MultiplexPolicy) {
        multiplexPolicy = policy
    }

    // MARK: - Subscribing

    /// Opens `request.channel` for `slot` and returns its subscription, replacing the slot's previous one.
    ///
    /// Joins the channel when it is already open, or when an open multiplex carries it (same device and frequency,
    /// known program number). Otherwise tunes on the best route (the device order of `orderedRoutes(for:released:)` for
    /// tiles, and for `.watch` with several routes), as a multiplex when the request or the policy asks for one. Throws
    /// the device's error (`.allTunersInUse`, `.noVideoData`, ...) after failing over through `request.routes`, and
    /// `.cancelled` when the calling task is cancelled, the slot was released, or a newer subscribe of the slot
    /// superseded this one.
    public func subscribe(_ request: TuneRequest, slot: SubscriberSlot = .player)
        async throws(HDHomeRunClientError) -> ChannelSubscription {
        let token = nextToken()
        // Close before open. A tuner we just released still shows as busy for about a second, but it's ours to reuse.
        var released = replaceSlot(slot, token: token)
        guard !request.routes.isEmpty else {
            clearSlot(slot, token: token)
            throw .unknownChannel
        }
        let claimed = try await claimOpenings(of: request, slot: slot, token: token)
        defer { endOpenings(claimed, token: token) }
        if let joined = join(request, slot: slot, released: &released) { return joined }
        let routes = await orderedRoutes(for: request, released: released)
        guard isCurrent(slot, token) else { throw .cancelled }
        var lastError = HDHomeRunClientError.allTunersInUse
        for ref in routes {
            do {
                return try await tune(ref, request: request, slot: slot, token: token, released: released)
            } catch {
                guard Self.allowsFailover(error) else { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    /// Joins a program upstream that is already open, at zero tuner cost: a relay client of another device of the
    /// same household. Throws `.unknownChannel` when the channel isn't open as a program stream here (a channel
    /// read from a multiplex can't be relayed: the client would get every program) or its upstream has stalled.
    public func attach(to channel: ChannelKey) throws(HDHomeRunClientError) -> ChannelSubscription {
        guard let upstream = upstreams[.program(channel)],
              upstream.fanout.isFresh(within: configuration.attachMaxSilence) else {
            throw .unknownChannel
        }
        let subscription = upstream.fanout.subscribe()
        guard !subscription.isEnded else { throw .unknownChannel }
        return subscription
    }

    /// A tuner this app was using elsewhere is being freed (another device that relayed a channel to us stopped),
    /// so an 805 within `busyRetryWindow` from now is retried once, as after our own release.
    public func expectRelease() {
        noteRelease()
    }

    /// Ends `slot`'s subscription (a tile removed, the player stopped) and abandons its request in flight. Its
    /// upstream closes unless another slot or a relay client still reads it.
    public func release(slot: SubscriberSlot) {
        _ = replaceSlot(slot, token: nextToken(), reason: .cancelled)
        slots[slot] = nil
    }

    /// Closes every stream, whoever watches it (window close, sleep, stop).
    public func releaseAll() {
        for slot in Array(slots.keys) {
            release(slot: slot)
        }
        for key in Array(upstreams.keys) {
            close(key, reason: .cancelled)
        }
    }

    // MARK: - Reading the state

    /// The route of the player's stream, or else of any open stream: which tuner is ours.
    public var currentRoute: StreamRoute? {
        if let player = slots[.player]?.subscription, !player.isEnded { return player.route }
        return openRoutes.first
    }

    /// The route `slot` reads now, or nil.
    public func route(of slot: SubscriberSlot) -> StreamRoute? {
        guard let subscription = slots[slot]?.subscription, !subscription.isEnded else { return nil }
        return subscription.route
    }

    /// Every open upstream's route (a multiplex by the channel that opened it), in channel order.
    public var openRoutes: [StreamRoute] {
        upstreams.values.map(\.fanout.route).sorted { $0.channel < $1.channel }
    }

    /// How many subscribers read `channel`, across its program upstream and any multiplex (0 when not open).
    public func subscriberCount(for channel: ChannelKey) -> Int {
        upstreams.values.reduce(0) { $0 + $1.fanout.subscriberCount(of: channel) }
    }

    // MARK: - Slots

    func nextToken() -> UInt64 {
        tokenCounter &+= 1
        return tokenCounter
    }

    func isCurrent(_ slot: SubscriberSlot, _ token: UInt64) -> Bool {
        slots[slot]?.token == token && !Task.isCancelled
    }

    /// Ends the slot's subscription and abandons its request in flight, and starts a new turn for it. Returns the
    /// tuner that freed, if its upstream closed.
    func replaceSlot(_ slot: SubscriberSlot, token: UInt64,
                     reason: TunerReleaseReason = .replaced) -> [ReleasedTuner] {
        let previous = slots[slot]
        slots[slot] = SlotState(token: token)
        if let waiting = previous?.pending {
            waiting.cancel()
            noteRelease()
        }
        guard let subscription = previous?.subscription else { return [] }
        subscription.end(reason)
        guard let (key, upstream) = upstreams.first(where: { $0.value.fanout === subscription.fanout }),
              upstream.fanout.isEnded else { return [] }
        forget(key, reason: reason)
        return [ReleasedTuner(deviceKey: upstream.deviceKey, tunerIndex: upstream.fanout.route.tunerIndex)]
    }

    func clearSlot(_ slot: SubscriberSlot, token: UInt64) {
        if slots[slot]?.token == token { slots[slot] = nil }
    }

    /// Joins the channel's open program upstream, or an open multiplex that carries it. A stalled upstream is
    /// closed instead (its other subscribers reconnect too), so a fresh GET replaces it.
    func join(_ request: TuneRequest, slot: SubscriberSlot, released: inout [ReleasedTuner]) -> ChannelSubscription? {
        var candidates: [(UpstreamKey, StreamRoute?)] = [(.program(request.channel), nil)]
        for ref in request.routes where ref.canShareMultiplex {
            guard let frequency = ref.frequency, let upstream = upstreams[.multiplex(device: ref.deviceKey,
                                                                                     frequency: frequency)] else {
                continue
            }
            let base = upstream.fanout.route
            let route = StreamRoute(channel: request.channel, deviceID: base.deviceID, resource: base.resource,
                                    contentType: base.contentType, programNumber: ref.programNumber,
                                    frequency: frequency)
            candidates.append((upstream.key, route))
        }
        for (key, route) in candidates {
            guard let upstream = upstreams[key] else { continue }
            if upstream.fanout.isFresh(within: configuration.attachMaxSilence) {
                let subscription = upstream.fanout.subscribe(route: route,
                                                             byteLimit: configuration.subscriberQueueBytes)
                if !subscription.isEnded {
                    slots[slot]?.subscription = subscription
                    return subscription
                }
            }
            released.append(ReleasedTuner(deviceKey: upstream.deviceKey, tunerIndex: upstream.fanout.route.tunerIndex))
            close(key, reason: .replaced)
        }
        return nil
    }

    // MARK: - Upstream bookkeeping

    /// Whether any slot of ours reads `upstream`. An upstream no slot reads is kept only for relay clients.
    func isReadBySlot(_ upstream: Upstream) -> Bool {
        slots.values.contains { state in
            guard let subscription = state.subscription else { return false }
            return subscription.fanout === upstream.fanout && !subscription.isEnded
        }
    }

    /// Bookkeeping after an upstream ended on its own (its last subscriber left, the device ended it, or it failed).
    /// Stale tokens are ignored: a newer upstream may already carry the key.
    func upstreamEnded(_ key: UpstreamKey, token: UInt64, reason: TunerReleaseReason) {
        guard let upstream = upstreams[key], upstream.token == token else { return }
        if case .failed = reason { recentFailures[upstream.deviceKey] = clock.now }
        forget(key, reason: reason)
    }

    /// Closes an upstream now, ending every subscriber.
    func close(_ key: UpstreamKey, reason: TunerReleaseReason) {
        guard let upstream = upstreams[key] else { return }
        forget(key, reason: reason)
        upstream.fanout.end(reason)
    }

    func forget(_ key: UpstreamKey, reason: TunerReleaseReason) {
        guard let upstream = upstreams.removeValue(forKey: key) else { return }
        noteRelease()
        eventSink.yield(.closed(upstream.fanout.route, reason))
    }

    func noteRelease() {
        lastRelease = clock.now
    }

    var releasedRecently: Bool {
        guard let lastRelease else { return false }
        return clock.now - lastRelease <= configuration.busyRetryWindow
    }

    /// 805, 806 and 807 may succeed on another device that carries the same channel.
    static func allowsFailover(_ error: HDHomeRunClientError) -> Bool {
        switch error {
        case .allTunersInUse, .tuneFailed, .noVideoData: true
        default: false
        }
    }
}
