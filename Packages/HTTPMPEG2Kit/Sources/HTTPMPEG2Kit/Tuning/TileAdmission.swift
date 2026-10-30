import Foundation

/// One device's tuners for the tile picker: data for text such as "3 of 4 tuners free (1 in use by 192.0.2.44)".
/// A hint: another client can take a free tuner at any moment.
public nonisolated struct DeviceCapacity: Sendable, Hashable {
    public let deviceID: TunerDeviceID?
    /// `DeviceChannelRef.deviceKey`.
    public let device: String
    /// Free, ours and others by the free-tuner rule. `others` carry each holder's `targetIP`, `vctNumber` and
    /// `vctName` ("tuner2 · 7.1 KMGH · 192.0.2.44").
    public let tuners: TunerCapacity
    /// "Keep N tuners free for others" when this was read.
    public let reserve: Int
    /// Free tuners that can receive ATSC 3.0 (all free tuners when the model is unknown).
    public let freeATSC3Capable: Int

    public init(deviceID: TunerDeviceID?, device: String, tuners: TunerCapacity, reserve: Int,
                atsc3CapableTuners: Set<Int>?) {
        self.deviceID = deviceID
        self.device = device
        self.tuners = tuners
        self.reserve = max(reserve, 0)
        freeATSC3Capable = atsc3CapableTuners.map { capable in
            tuners.free.filter { $0.tunerIndex.map(capable.contains) ?? false }.count
        } ?? tuners.free.count
    }

    public var total: Int { tuners.total }
    public var free: Int { tuners.free.count }
    /// Tuners carrying our own streams (tiles, the player, relay clients we serve).
    public var ours: Int { tuners.ours.count }
    /// Tuners held by other clients: another TV, a DVR.
    public var others: [TunerStatus] { tuners.others }
    /// Free tuners a new tile may use: free minus the reserve.
    public var availableAfterReserve: Int { max(free - reserve, 0) }
}

/// Whether one more tile can open a channel now, and at what cost. The app adapts it to multi-view's capacity
/// check; it is a hint taken from `status.json`, and the subscribe that follows is the real check.
public nonisolated enum TileAdmission: Sendable, Hashable {
    /// Costs no tuner: the channel is open (`route` is what the tile would join), or an open multiplex carries it.
    case free(joining: StreamRoute)
    /// Takes one tuner on this device. `capacity` is nil when the broker can't read `status.json` (a `.watch`
    /// request is never checked). `takesLastFreeTuner`: with the reserve at 0 this tile would leave no tuner free,
    /// so the UI should warn that recordings on other devices may fail.
    case needsTuner(deviceID: TunerDeviceID?, capacity: DeviceCapacity?, takesLastFreeTuner: Bool)
    /// No tuner is free, but `slot` reads `channel` as a program stream on the same device and frequency.
    /// Re-tuning that slot onto the multiplex (subscribe its request again with `prefersMultiplex`, a 1–3 s restart
    /// for it) makes room: this request then joins at zero cost.
    case retuneOntoMultiplex(slot: SubscriberSlot, channel: ChannelKey, deviceID: TunerDeviceID?, frequency: Int)
    case unavailable(TileUnavailableReason)

    /// Whether a tile can be added without anyone's help.
    public var isAvailable: Bool {
        switch self {
        case .free, .needsTuner: true
        case .retuneOntoMultiplex, .unavailable: false
        }
    }
}

public nonisolated enum TileUnavailableReason: Sendable, Hashable {
    /// The request lists no device.
    case noRoutes
    /// Every device that carries the channel has fewer than 1 + reserve free tuners.
    case noFreeTuner([DeviceCapacity])
    /// Tuners are free, but none of them can receive ATSC 3.0.
    case atsc3TunersBusy([DeviceCapacity])
    /// `status.json` couldn't be read (no reader, or the device didn't answer).
    case statusUnavailable
}

extension TunerBroker {
    /// One device's tuners, with our own streams counted as ours. Uses a cached `status.json` younger than `maxAge`.
    /// Throws `.invalidResponse` when the broker has no status fetcher.
    public func capacitySummary(of ref: DeviceChannelRef, maxAge: Duration? = nil)
        async throws(HDHomeRunClientError) -> DeviceCapacity {
        DeviceCapacity(deviceID: ref.deviceID, device: ref.deviceKey,
                       tuners: try await capacity(of: ref, maxAge: maxAge), reserve: reserve,
                       atsc3CapableTuners: ref.atsc3CapableTuners)
    }

    /// Every device among `refs` once, in order, skipping devices whose `status.json` couldn't be read.
    public func capacitySummaries(of refs: [DeviceChannelRef], maxAge: Duration? = nil) async -> [DeviceCapacity] {
        var seen = Set<String>()
        var summaries: [DeviceCapacity] = []
        for ref in refs where seen.insert(ref.deviceKey).inserted {
            if let summary = try? await capacitySummary(of: ref, maxAge: maxAge) { summaries.append(summary) }
        }
        return summaries
    }

    /// The device's tuners by the free-tuner rule, with our own streams counted as ours. Uses a cached `status.json`
    /// younger than `maxAge`. Throws `.invalidResponse` when the broker has no status fetcher.
    public func capacity(of ref: DeviceChannelRef, maxAge: Duration? = nil)
        async throws(HDHomeRunClientError) -> TunerCapacity {
        let statuses = try await status(of: ref, maxAge: maxAge ?? configuration.statusMaxAge)
        let ours = upstreams.values.filter { $0.deviceKey == ref.deviceKey }.compactMap(\.fanout.route.resource)
        return TunerCapacity(statuses: statuses, ourResources: Set(ours))
    }

    /// What adding `request` (usually a `.tile`) would cost now. `.watch` is never refused.
    public func admission(for request: TuneRequest) async -> TileAdmission {
        guard let first = request.routes.first else { return .unavailable(.noRoutes) }
        if let route = joinableRoute(for: request) { return .free(joining: route) }
        if request.purpose == .watch {
            let capacity = fetchStatus == nil ? nil : try? await capacitySummary(of: first)
            return .needsTuner(deviceID: first.deviceID, capacity: capacity, takesLastFreeTuner: false)
        }
        guard fetchStatus != nil else { return .unavailable(.statusUnavailable) }
        let required = request.purpose.requiredFreeTuners(reserve: reserve) ?? 1
        var capacities: [DeviceCapacity] = []
        for ref in await orderedRoutes(for: request, released: []) {
            guard let capacity = try? await capacitySummary(of: ref) else { continue }
            capacities.append(capacity)
            let ofKind = ref.isATSC3 ? capacity.freeATSC3Capable : capacity.free
            // Upstreams kept only for relay clients make way for the local user.
            let relayOnly = upstreams.values.filter { $0.deviceKey == ref.deviceKey && !isReadBySlot($0) }.count
            if capacity.free + relayOnly >= required, ofKind + relayOnly >= 1 {
                return .needsTuner(deviceID: ref.deviceID, capacity: capacity,
                                   takesLastFreeTuner: capacity.free == 1)
            }
        }
        if let offer = retuneOffer(for: request) { return offer }
        if capacities.isEmpty { return .unavailable(.statusUnavailable) }
        if request.routes.contains(where: \.isATSC3), capacities.contains(where: { $0.free >= required }) {
            return .unavailable(.atsc3TunersBusy(capacities))
        }
        return .unavailable(.noFreeTuner(capacities))
    }

    /// Plans `requests` (channels not open yet) on the free tuners after the reserve with the current policy, each
    /// on its first route's device. Subscribe the channels in `multiplexedChannels` with `prefersMultiplex`, the
    /// multiplexes first. Without a status fetcher every device counts as having no free tuner.
    public func plan(_ requests: [TuneRequest]) async -> MultiViewPlan {
        var devices: [String: DeviceTunerState] = [:]
        var channels: [PlannerChannel] = []
        for request in requests {
            guard let ref = request.routes.first else { continue }
            channels.append(PlannerChannel(channel: request.channel, route: ref))
            guard devices[ref.deviceKey] == nil else { continue }
            let statuses = fetchStatus == nil ? [] : (try? await status(of: ref, maxAge: configuration.statusMaxAge))
            devices[ref.deviceKey] = DeviceTunerState(
                device: ref.deviceKey,
                freeTuners: TunerCapacity(statuses: statuses ?? []).free.compactMap(\.tunerIndex),
                atsc3CapableTuners: ref.atsc3CapableTuners, reserve: reserve)
        }
        return MultiViewPlanner.plan(requested: channels, devices: Array(devices.values), policy: multiplexPolicy)
    }

    /// The route a subscribe of `request` would join now, at zero tuner cost.
    func joinableRoute(for request: TuneRequest) -> StreamRoute? {
        let silence = configuration.attachMaxSilence
        if let upstream = upstreams[.program(request.channel)], upstream.fanout.isFresh(within: silence) {
            return upstream.fanout.route
        }
        for ref in request.routes where ref.canShareMultiplex {
            guard let frequency = ref.frequency,
                  let upstream = upstreams[.multiplex(device: ref.deviceKey, frequency: frequency)],
                  upstream.fanout.isFresh(within: silence) else { continue }
            let base = upstream.fanout.route
            return StreamRoute(channel: request.channel, deviceID: base.deviceID, resource: base.resource,
                               contentType: base.contentType, programNumber: ref.programNumber, frequency: frequency)
        }
        return nil
    }

    /// A second channel on the frequency of one of our program streams, with no tuner free: offers to re-tune the slot
    /// reading that program stream onto the multiplex.
    func retuneOffer(for request: TuneRequest) -> TileAdmission? {
        guard multiplexPolicy != .never, fetchStatus != nil else { return nil }
        for ref in request.routes where ref.canShareMultiplex {
            for upstream in upstreams.values where upstream.deviceKey == ref.deviceKey
                && upstream.frequency == ref.frequency {
                guard case .program(let channel) = upstream.key, channel != request.channel,
                      let frequency = ref.frequency,
                      let slot = slots.first(where: { $0.value.subscription?.fanout === upstream.fanout })?.key,
                      isReadBySlot(upstream)
                else { continue }
                return .retuneOntoMultiplex(slot: slot, channel: channel, deviceID: ref.deviceID, frequency: frequency)
            }
        }
        return nil
    }
}
