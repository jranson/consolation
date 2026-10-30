import Foundation

/// Why a channel is being tuned. It decides whether the broker checks for a free tuner first.
public nonisolated enum TunePurpose: Sendable, Hashable {
    /// The stream the user explicitly started. Never blocked by the reserve: the GET itself is the check, and an
    /// 805 is normal flow.
    case watch
    /// A multi-view tile. Needs a free tuner after the reserve.
    case tile
    /// Background guide collection. Needs two free tuners after the reserve.
    case guideHarvest

    /// The free tuners `status.json` must show before this purpose may tune, or nil when no check is made.
    public func requiredFreeTuners(reserve: Int) -> Int? {
        switch self {
        case .watch: nil
        case .tile: 1 + max(reserve, 0)
        case .guideHarvest: 2 + max(reserve, 0)
        }
    }
}

/// One device's way to reach a channel: its stream URL and, from `lineup.json?tuning`, where it sits on the air.
/// Only the broker reads `url`; it is never handed to a player.
public nonisolated struct DeviceChannelRef: Sendable, Hashable {
    /// The device carrying the channel, when known. Routing only; never part of a channel identity.
    public var deviceID: TunerDeviceID?
    /// The program stream URL, for example `http://<device>:5004/auto/v7.1`.
    public var url: URL
    /// The RF frequency in Hz, when the lineup was loaded with `?tuning`. Needed for multiplex sharing.
    public var frequency: Int?
    /// The MPEG program number on that frequency, when known. Needed for multiplex sharing.
    public var programNumber: Int?
    /// `discover.json` `ModelNumber` (for example `HDFX-4K`): which tuners can receive ATSC 3.0.
    public var modelNumber: String?
    /// The lineup's `SignalQuality` for this channel on this device (0–100), for choosing between devices.
    public var signalQuality: Int?
    /// An ATSC 3.0 channel: only 3.0-capable tuners carry it, and it is never shared as a multiplex.
    public var isATSC3: Bool

    public init(deviceID: TunerDeviceID? = nil, url: URL, frequency: Int? = nil, programNumber: Int? = nil,
                modelNumber: String? = nil, signalQuality: Int? = nil, isATSC3: Bool = false) {
        self.deviceID = deviceID
        self.url = url
        self.frequency = frequency
        self.programNumber = programNumber
        self.modelNumber = modelNumber
        self.signalQuality = signalQuality
        self.isATSC3 = isATSC3
    }

    /// Identifies the device for status caches, multiplex keys and the planner: the DeviceID when known,
    /// otherwise the URL's host.
    public var deviceKey: String {
        deviceID?.rawValue ?? url.host() ?? url.absoluteString
    }

    /// The tuner indices that can receive ATSC 3.0, or nil when the model is unknown (then every tuner may be).
    public var atsc3CapableTuners: Set<Int>? {
        TunerModelTable.atsc3CapableTuners(modelNumber: modelNumber)
    }

    /// Whether this route can share a full-multiplex upstream: an ATSC 1.0 channel with a known frequency and
    /// program number.
    public var canShareMultiplex: Bool {
        !isATSC3 && frequency != nil && programNumber != nil
    }

    /// The full-multiplex URL on one named tuner, `/tuner<N>/ch<frequencyHz>`, on the same scheme, host and port
    /// as `url`. Nil without a frequency.
    public func multiplexURL(tuner: Int) -> URL? {
        guard let frequency, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/tuner\(tuner)/ch\(frequency)"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

/// What a subscriber asks the broker for: a channel, the devices that can carry it in order of preference, and why.
public nonisolated struct TuneRequest: Sendable, Hashable {
    public var channel: ChannelKey
    /// Candidate devices, best first. On 805, 806 or 807 the broker fails over to the next one.
    public var routes: [DeviceChannelRef]
    public var purpose: TunePurpose
    /// Open the channel as a full multiplex even when `MultiplexPolicy` would open a program stream: a tile the
    /// planner placed on a shared multiplex, or one re-tuned onto it to make room (`TileAdmission.retuneOntoMultiplex`).
    /// Ignored for routes that can't share (ATSC 3.0, unknown frequency or program).
    public var prefersMultiplex: Bool

    public init(channel: ChannelKey, routes: [DeviceChannelRef], purpose: TunePurpose = .watch,
                prefersMultiplex: Bool = false) {
        self.channel = channel
        self.routes = routes
        self.purpose = purpose
        self.prefersMultiplex = prefersMultiplex
    }
}

/// Where an open subscription's bytes come from. Deliberately carries no URL, host or address.
public nonisolated struct StreamRoute: Sendable, Hashable {
    public let channel: ChannelKey
    public let deviceID: TunerDeviceID?
    /// `X-HDHomeRun-Resource`, the tuner carrying the stream, for example `tuner2`.
    public let resource: String?
    /// `Content-Type`, for example `video/mpeg`.
    public let contentType: String?
    /// The program to select from the PAT. Nil for a program stream, which carries only one program.
    public let programNumber: Int?
    /// The RF frequency of a full-multiplex upstream; nil for a program stream.
    public let frequency: Int?

    public init(channel: ChannelKey, deviceID: TunerDeviceID?, resource: String?, contentType: String?,
                programNumber: Int?, frequency: Int? = nil) {
        self.channel = channel
        self.deviceID = deviceID
        self.resource = resource
        self.contentType = contentType
        self.programNumber = programNumber
        self.frequency = frequency
    }

    /// Whether the bytes are a whole multiplex shared with other channels.
    public var isMultiplex: Bool { frequency != nil }

    /// `2` for `tuner2`.
    var tunerIndex: Int? { resource.flatMap(TunerModelTable.tunerIndex) }
}

/// One unit of a subscription's transport stream.
public nonisolated enum TSChunk: Sendable, Equatable {
    case data(Data)
    /// Bytes were dropped before this point (the subscriber fell behind and its bounded queue overflowed); the
    /// demuxer should resync. Relay clients never get one: a slow relay client is disconnected instead.
    case discontinuity
}

/// Why an upstream closed.
public nonisolated enum TunerReleaseReason: Sendable, Equatable {
    /// The subscriber cancelled.
    case cancelled
    /// A newer subscription took over: the player tuned another channel or reconnected, or a relay-only upstream
    /// made way for this device's own player.
    case replaced
    /// The device ended the stream normally, for example after `?duration=`.
    case ended
    /// The stream failed mid-way.
    case failed(HDHomeRunClientError)
}

/// What the broker reports to the app, at low frequency.
///
/// There is no separate "lease lost" event: when an upstream fails, the broker reports `.closed(route, .failed)`
/// and every subscription's `chunks` throws; the engine then reconnects (after 1 s and 3 s, each a new `subscribe`
/// that fails over through the request's routes) and its final failure is the lease being lost.
public nonisolated enum TunerEvent: Sendable, Equatable {
    case opened(StreamRoute)
    case closed(StreamRoute, TunerReleaseReason)
}
