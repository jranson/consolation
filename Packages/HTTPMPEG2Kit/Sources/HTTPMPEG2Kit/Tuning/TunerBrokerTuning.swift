import Foundation

/// Tuning: device order, free-tuner checks, multiplex tuner choice, the GET with its 805 retry, and activation.
extension TunerBroker {
    /// Where one GET goes and what its upstream carries.
    struct OpenTarget {
        let channel: ChannelKey
        let url: URL
        let key: UpstreamKey
        /// Set for a multiplex: the program the requesting channel selects from the PAT.
        let programNumber: Int?
        let multiplexFrequency: Int?
        /// The URL names a tuner one of our own upstreams just released, so a 804 right after is retried once.
        let namesReleasedTuner: Bool

        static func program(_ request: TuneRequest, _ ref: DeviceChannelRef) -> OpenTarget {
            OpenTarget(channel: request.channel, url: ref.url, key: .program(request.channel), programNumber: nil,
                       multiplexFrequency: nil, namesReleasedTuner: false)
        }

        func retries(_ error: HDHomeRunClientError) -> Bool {
            error == .allTunersInUse || (error == .tunerInUse && namesReleasedTuner)
        }
    }

    /// One route: the free-tuner check, room for the local user, then a multiplex or a program stream.
    func tune(_ ref: DeviceChannelRef, request: TuneRequest, slot: SubscriberSlot, token: UInt64,
              released: [ReleasedTuner]) async throws(HDHomeRunClientError) -> ChannelSubscription {
        let releasing = released.filter { $0.deviceKey == ref.deviceKey }
        // A slot that gives back its own tuner on this device (a reconnect, a channel change, a re-tune onto the
        // multiplex) adds nothing, so the reserve doesn't apply to it.
        let purpose = releasing.isEmpty ? request.purpose : .watch
        try await checkFreeTuners(ref, purpose: purpose, releasing: releasing.count, slot: slot, token: token)
        try await makeRoom(on: ref, needed: purpose.requiredFreeTuners(reserve: reserve) ?? 1,
                           releasing: releasing.count, slot: slot, token: token)
        if wantsMultiplex(request, ref) {
            return try await openMultiplex(ref, request: request, slot: slot, token: token, releasing: releasing)
        }
        return try await open(.program(request, ref), ref: ref, request: request, slot: slot, token: token)
    }

    func wantsMultiplex(_ request: TuneRequest, _ ref: DeviceChannelRef) -> Bool {
        guard ref.canShareMultiplex, fetchStatus != nil else { return false }
        switch multiplexPolicy {
        case .never: return false
        case .whenTunersAreShort: return request.prefersMultiplex
        case .always: return request.prefersMultiplex || request.purpose == .tile
        }
    }

    /// Opens `ref`'s whole multiplex on a named free tuner, preferring one that can't receive ATSC 3.0. On 804 (the
    /// tuner was taken meanwhile) it re-plans on another tuner of the same device with a fresh `status.json`; with
    /// no tuner left to name it falls back to a program stream.
    func openMultiplex(_ ref: DeviceChannelRef, request: TuneRequest, slot: SubscriberSlot, token: UInt64,
                       releasing: [ReleasedTuner]) async throws(HDHomeRunClientError) -> ChannelSubscription {
        guard let frequency = ref.frequency else {
            return try await open(.program(request, ref), ref: ref, request: request, slot: slot, token: token)
        }
        let key = UpstreamKey.multiplex(device: ref.deviceKey, frequency: frequency)
        let ours = releasing.compactMap(\.tunerIndex)
        var tried = Set<Int>()
        for round in 0..<4 {
            let maxAge = round == 0 ? configuration.statusMaxAge : .zero
            guard let statuses = try? await status(of: ref, maxAge: maxAge) else { break }
            guard isCurrent(slot, token) else { throw .cancelled }
            let free = TunerCapacity(statuses: statuses).free.compactMap(\.tunerIndex) + ours
            let candidates = free.filter { !tried.contains($0) }
            guard let tuner = MultiViewPlanner.pickTuner(from: candidates, atsc3Capable: ref.atsc3CapableTuners,
                                                         needsATSC3: false),
                  let url = ref.multiplexURL(tuner: tuner) else { break }
            tried.insert(tuner)
            let target = OpenTarget(channel: request.channel, url: url, key: key, programNumber: ref.programNumber,
                                    multiplexFrequency: frequency, namesReleasedTuner: ours.contains(tuner))
            do {
                return try await open(target, ref: ref, request: request, slot: slot, token: token)
            } catch {
                guard error == .tunerInUse else { throw error }
            }
        }
        return try await open(.program(request, ref), ref: ref, request: request, slot: slot, token: token)
    }

    /// One GET, with the single 805 retry right after our own release.
    func open(_ target: OpenTarget, ref: DeviceChannelRef, request: TuneRequest, slot: SubscriberSlot,
              token: UInt64) async throws(HDHomeRunClientError) -> ChannelSubscription {
        for attempt in 0..<2 {
            let stream = makeStream(target.url)
            slots[slot]?.pending = stream
            let result: Result<StreamOpenInfo, HDHomeRunClientError>
            do {
                result = .success(try await stream.open())
            } catch {
                result = .failure(error)
            }
            if let waiting = slots[slot]?.pending, waiting === stream { slots[slot]?.pending = nil }
            guard isCurrent(slot, token) else {
                stream.cancel()
                noteRelease()
                throw .cancelled
            }
            switch result {
            case .success(let info):
                return activate(stream, info: info, target: target, ref: ref, slot: slot)
            case .failure(let error) where attempt == 0 && target.retries(error):
                stream.cancel()
                // Upstreams kept only for relay clients make way for the local user.
                closeRelayOnly(on: ref)
                guard releasedRecently else { throw error }
                try await pause(configuration.busyRetryDelay, slot: slot, token: token)
            case .failure(let error):
                stream.cancel()
                throw error
            }
        }
        throw .allTunersInUse
    }

    func activate(_ stream: any TunerStream, info: StreamOpenInfo, target: OpenTarget, ref: DeviceChannelRef,
                  slot: SubscriberSlot) -> ChannelSubscription {
        let route = StreamRoute(channel: target.channel, deviceID: ref.deviceID, resource: info.resource,
                                contentType: info.contentType, programNumber: target.programNumber,
                                frequency: target.multiplexFrequency)
        upstreamCount &+= 1
        let token = upstreamCount
        let key = target.key
        let fanout = UpstreamFanout(route: route, upstream: stream) { [weak self] reason in
            Task { await self?.upstreamEnded(key, token: token, reason: reason) }
        }
        if upstreams[key] != nil { close(key, reason: .replaced) }
        upstreams[key] = Upstream(token: token, key: key, fanout: fanout, deviceKey: ref.deviceKey,
                                  frequency: ref.frequency)
        let subscription = fanout.subscribe(byteLimit: configuration.subscriberQueueBytes)
        slots[slot]?.subscription = subscription
        fanout.start()
        eventSink.yield(.opened(route))
        return subscription
    }

    // MARK: - Device choice

    /// The request's routes in preference order: devices with a free tuner of the right kind (after the reserve) first,
    /// then the highest signal quality, then the most free tuners; a device whose upstream just failed goes last. A
    /// single route keeps its order without reading `status.json` (the user's stream is never checked).
    func orderedRoutes(for request: TuneRequest, released: [ReleasedTuner]) async -> [DeviceChannelRef] {
        guard request.routes.count > 1 else { return request.routes }
        let required = request.purpose.requiredFreeTuners(reserve: reserve) ?? 1
        var ranks: [RouteRank] = []
        for (index, ref) in request.routes.enumerated() {
            var free: Int?
            if fetchStatus != nil, let statuses = try? await status(of: ref, maxAge: configuration.statusMaxAge) {
                let releasing = released.filter { $0.deviceKey == ref.deviceKey }.count
                free = Self.freeTuners(TunerCapacity(statuses: statuses), for: ref).count + releasing
            }
            let failedAt = recentFailures[ref.deviceKey]
            ranks.append(RouteRank(index: index, ref: ref,
                                   failedRecently: failedAt.map { clock.now - $0 < configuration.failedDevicePenalty }
                                       ?? false,
                                   fits: free.map { $0 >= required } ?? true, free: free ?? 0))
        }
        return ranks.sorted(by: RouteRank.isBetter).map(\.ref)
    }

    struct RouteRank {
        let index: Int
        let ref: DeviceChannelRef
        let failedRecently: Bool
        let fits: Bool
        let free: Int

        static func isBetter(_ lhs: RouteRank, _ rhs: RouteRank) -> Bool {
            if lhs.failedRecently != rhs.failedRecently { return !lhs.failedRecently }
            if lhs.fits != rhs.fits { return lhs.fits }
            let lhsQuality = lhs.ref.signalQuality ?? 0
            let rhsQuality = rhs.ref.signalQuality ?? 0
            if lhsQuality != rhsQuality { return lhsQuality > rhsQuality }
            if lhs.free != rhs.free { return lhs.free > rhs.free }
            return lhs.index < rhs.index
        }
    }

    /// The free tuners that can carry `ref`: any for ATSC 1.0, 3.0-capable ones for ATSC 3.0.
    static func freeTuners(_ capacity: TunerCapacity, for ref: DeviceChannelRef) -> [TunerStatus] {
        guard ref.isATSC3, let capable = ref.atsc3CapableTuners else { return capacity.free }
        return capacity.free.filter { $0.tunerIndex.map(capable.contains) ?? false }
    }

    // MARK: - Checks

    func checkFreeTuners(_ ref: DeviceChannelRef, purpose: TunePurpose, releasing: Int, slot: SubscriberSlot,
                         token: UInt64) async throws(HDHomeRunClientError) {
        guard let required = purpose.requiredFreeTuners(reserve: reserve), fetchStatus != nil else { return }
        let statuses = try await status(of: ref, maxAge: configuration.statusMaxAge)
        guard isCurrent(slot, token) else { throw .cancelled }
        let capacity = TunerCapacity(statuses: statuses)
        // Upstreams kept only for relay clients make way for the local user, so their tuners count as available.
        let relayOnly = upstreams.values.filter { $0.deviceKey == ref.deviceKey && !isReadBySlot($0) }.count
        guard capacity.free.count + releasing + relayOnly >= required else { throw .allTunersInUse }
        if ref.isATSC3, releasing == 0, Self.freeTuners(capacity, for: ref).isEmpty { throw .allTunersInUse }
    }

    /// A slot is about to tune on `ref`'s device while upstreams kept only for relay clients hold tuners there.
    /// They stay when `status.json` shows the `needed` free tuners (1, or 1 + reserve for a tile); otherwise they
    /// close first.
    func makeRoom(on ref: DeviceChannelRef, needed: Int, releasing: Int, slot: SubscriberSlot, token: UInt64)
        async throws(HDHomeRunClientError) {
        guard upstreams.values.contains(where: { $0.deviceKey == ref.deviceKey && !isReadBySlot($0) }) else { return }
        var free = 0
        if fetchStatus != nil, let statuses = try? await status(of: ref, maxAge: configuration.statusMaxAge) {
            free = TunerCapacity(statuses: statuses).free.count + releasing
        }
        guard isCurrent(slot, token) else { throw .cancelled }
        if free < needed { closeRelayOnly(on: ref) }
    }

    /// Closes the upstreams on `ref`'s device that no slot reads (kept only for relay clients).
    func closeRelayOnly(on ref: DeviceChannelRef) {
        let keys = upstreams.values.filter { $0.deviceKey == ref.deviceKey && !isReadBySlot($0) }.map(\.key)
        for key in keys {
            close(key, reason: .replaced)
        }
    }

    func status(of ref: DeviceChannelRef, maxAge: Duration) async throws(HDHomeRunClientError) -> [TunerStatus] {
        guard let fetchStatus else { throw .invalidResponse }
        let key = ref.deviceKey
        if let cached = statusCache[key], clock.now - cached.fetched <= maxAge {
            return cached.statuses
        }
        let statuses = try await fetchStatus(ref)
        statusCache[key] = (clock.now, statuses)
        return statuses
    }

    func pause(_ delay: Duration, slot: SubscriberSlot, token: UInt64) async throws(HDHomeRunClientError) {
        do {
            try await Task.sleep(for: delay)
        } catch {
            throw .cancelled
        }
        guard isCurrent(slot, token) else { throw .cancelled }
    }

    // MARK: - Openings in flight

    /// Waits while another slot is opening an upstream this request could join, then claims the upstreams this
    /// request may open, so two tiles asking for the same channel (or multiplex) at once take one tuner, not two.
    /// Returns the claimed keys; the caller ends them when it is done.
    func claimOpenings(of request: TuneRequest, slot: SubscriberSlot, token: UInt64)
        async throws(HDHomeRunClientError) -> [UpstreamKey] {
        var keys: [UpstreamKey] = [.program(request.channel)]
        var claimed = keys
        for ref in request.routes where ref.canShareMultiplex {
            guard let frequency = ref.frequency else { continue }
            let key = UpstreamKey.multiplex(device: ref.deviceKey, frequency: frequency)
            keys.append(key)
            if wantsMultiplex(request, ref) { claimed.append(key) }
        }
        while let key = keys.first(where: { opening[$0].map { $0.slot != slot } ?? false }) {
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                if opening[key] != nil {
                    opening[key]?.waiters.append(waiter)
                } else {
                    waiter.resume()
                }
            }
            guard isCurrent(slot, token) else { throw .cancelled }
        }
        // No suspension between the last check and the claims.
        for key in claimed { beginOpening(key, slot: slot, token: token) }
        return claimed
    }

    func beginOpening(_ key: UpstreamKey, slot: SubscriberSlot, token: UInt64) {
        let waiters = opening[key]?.waiters ?? []
        opening[key] = Opening(slot: slot, token: token, waiters: waiters)
    }

    func endOpenings(_ keys: [UpstreamKey], token: UInt64) {
        for key in keys {
            guard let entry = opening[key], entry.token == token else { continue }
            opening[key] = nil
            for waiter in entry.waiters { waiter.resume() }
        }
    }
}
