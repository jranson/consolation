import Foundation

/// One channel the planner should place, on one device.
public nonisolated struct PlannerChannel: Sendable, Hashable {
    public var channel: ChannelKey
    /// `DeviceChannelRef.deviceKey` of the device that would carry it.
    public var device: String
    /// RF frequency in Hz and program number from `lineup.json?tuning`; both are needed to share a multiplex.
    public var frequency: Int?
    public var programNumber: Int?
    public var isATSC3: Bool

    public init(channel: ChannelKey, device: String, frequency: Int?, programNumber: Int?, isATSC3: Bool = false) {
        self.channel = channel
        self.device = device
        self.frequency = frequency
        self.programNumber = programNumber
        self.isATSC3 = isATSC3
    }

    /// The channel on `route`'s device.
    public init(channel: ChannelKey, route: DeviceChannelRef) {
        self.init(channel: channel, device: route.deviceKey, frequency: route.frequency,
                  programNumber: route.programNumber, isATSC3: route.isATSC3)
    }

    var canShareMultiplex: Bool { !isATSC3 && frequency != nil && programNumber != nil }
}

/// One device's free tuners for the planner.
public nonisolated struct DeviceTunerState: Sendable, Hashable {
    public var device: String
    /// Indices of the free tuners by the free-tuner rule, for example `[0, 1, 3]`.
    public var freeTuners: [Int]
    /// From `TunerModelTable`; nil when unknown (every tuner may receive ATSC 3.0).
    public var atsc3CapableTuners: Set<Int>?
    /// Tuners to leave free for others.
    public var reserve: Int

    public init(device: String, freeTuners: [Int], atsc3CapableTuners: Set<Int>?, reserve: Int = 0) {
        self.device = device
        self.freeTuners = freeTuners
        self.atsc3CapableTuners = atsc3CapableTuners
        self.reserve = reserve
    }
}

/// One upstream the plan opens.
public nonisolated enum PlannedStream: Sendable, Hashable {
    /// A program stream (`/auto/v<GuideNumber>`); the device picks the tuner.
    case program(device: String, channel: ChannelKey)
    /// A full multiplex on a named tuner (`/tuner<N>/ch<frequency>`), demuxed into several channels.
    case multiplex(device: String, tuner: Int, frequency: Int, programs: [Int], channels: [ChannelKey])
}

/// Where requested channels go. Open the multiplexes first: a program stream on `/auto/` may otherwise take the
/// tuner a multiplex was planned on (the broker then re-plans on another tuner, 804).
public nonisolated struct MultiViewPlan: Sendable, Hashable {
    public var streams: [PlannedStream] = []
    /// Channels that don't fit in the free tuners (after the reserve), in request order.
    public var unplaced: [ChannelKey] = []

    public init(streams: [PlannedStream] = [], unplaced: [ChannelKey] = []) {
        self.streams = streams
        self.unplaced = unplaced
    }

    /// The channels placed on a shared multiplex: subscribe these with `TuneRequest.prefersMultiplex`.
    public var multiplexedChannels: Set<ChannelKey> {
        Set(streams.flatMap { stream -> [ChannelKey] in
            if case .multiplex(_, _, _, _, let channels) = stream { return channels }
            return []
        })
    }
}

/// Places channels on free tuners: channels on one RF multiplex share one tuner when the policy allows, ATSC 1.0 work
/// prefers tuners that can't receive ATSC 3.0, and ATSC 3.0 channels go only to 3.0-capable tuners as program streams.
/// Pure; the broker uses the same tuner choice when it opens a multiplex.
public nonisolated enum MultiViewPlanner {
    public static func plan(requested: [PlannerChannel], devices: [DeviceTunerState],
                            policy: MultiplexPolicy) -> MultiViewPlan {
        var seen = Set<ChannelKey>()
        let channels = requested.filter { seen.insert($0.channel).inserted }
        var pools = Dictionary(devices.map { ($0.device, $0) }, uniquingKeysWith: { first, _ in first })
        var budgets = pools.mapValues { max($0.freeTuners.count - max($0.reserve, 0), 0) }
        let groups = Dictionary(grouping: channels.filter(\.canShareMultiplex)) { GroupKey($0) }
        let sharing = Set(pools.keys.filter { device in
            shares(policy: policy, distinct: channels.filter { $0.device == device }.count,
                   budget: budgets[device] ?? 0)
        })
        var plan = MultiViewPlan()
        var placed = Set<ChannelKey>()
        for channel in channels where !placed.contains(channel.channel) {
            let group = channel.canShareMultiplex ? groups[GroupKey(channel)] ?? [channel] : [channel]
            let multiplexed = sharing.contains(channel.device) && channel.canShareMultiplex
                && (group.count > 1 || policy == .always)
            let members = multiplexed ? group : [channel]
            placed.formUnion(members.map(\.channel))
            guard let state = pools[channel.device], budgets[channel.device, default: 0] > 0,
                  let tuner = pickTuner(from: state.freeTuners, atsc3Capable: state.atsc3CapableTuners,
                                        needsATSC3: channel.isATSC3) else {
                plan.unplaced += members.map(\.channel)
                continue
            }
            pools[channel.device]?.freeTuners.removeAll { $0 == tuner }
            budgets[channel.device, default: 0] -= 1
            if multiplexed, let frequency = channel.frequency {
                plan.streams.append(.multiplex(device: channel.device, tuner: tuner, frequency: frequency,
                                               programs: members.compactMap(\.programNumber),
                                               channels: members.map(\.channel)))
            } else {
                plan.streams.append(.program(device: channel.device, channel: channel.channel))
            }
        }
        return plan
    }

    /// The tuner for new work: an ATSC 3.0 channel needs a 3.0-capable tuner; ATSC 1.0 work prefers one that isn't
    /// 3.0-capable, so 3.0 tuners stay available. Unknown models (nil) count every tuner as 3.0-capable.
    public static func pickTuner(from free: [Int], atsc3Capable: Set<Int>?, needsATSC3: Bool) -> Int? {
        if needsATSC3 {
            return free.first { atsc3Capable?.contains($0) ?? true }
        }
        return free.first { atsc3Capable?.contains($0) == false } ?? free.first
    }

    /// Whether a device's channels share multiplexes under `policy`.
    static func shares(policy: MultiplexPolicy, distinct: Int, budget: Int) -> Bool {
        switch policy {
        case .never: false
        case .always: true
        case .whenTunersAreShort: distinct > budget
        }
    }

    private struct GroupKey: Hashable {
        let device: String
        let frequency: Int?

        init(_ channel: PlannerChannel) {
            device = channel.device
            frequency = channel.frequency
        }
    }
}
