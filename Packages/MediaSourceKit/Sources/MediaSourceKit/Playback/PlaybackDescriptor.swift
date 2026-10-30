import Foundation
import HTTPMPEG2Kit

/// How to play one item: what `MediaSource.playback(for:request:)` returns.
///
/// It carries source-side facts (the lease, the start position, request headers, whether a recording is still
/// growing). `PlaybackInputMapper` turns it into an engine input; engines never see a descriptor, a lease or a
/// source. Descriptors live only in memory: never persist or log one. Every textual form (`description`,
/// `String(reflecting:)` and `dump()`) redacts URLs to scheme and host and headers to their names.
public nonisolated struct PlaybackDescriptor: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    public nonisolated enum Transport: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
        CustomReflectable {
        /// A live channel from the tuner broker; the engine never sees a device URL. The `TunerLease` holds the
        /// open subscription, reopens the channel for the engine's silent reconnects, and is also the
        /// descriptor's `lease`.
        case liveTuner(TunerLease)
        /// A Range-capable file over HTTP: a Plex part, a DVR PlayURL, a DLNA resource.
        case http(URL, headers: [String: String])
        /// A local or OS-mounted file that is not growing.
        case file(URL)
        /// In-app SMB or NFS, and growing local or mounted files.
        case bytes(any ByteRangeSource)
        case hls(URL, headers: [String: String])
        case dash(URL)

        /// Redacted: scheme and host only, header names without values.
        public var description: String {
            switch self {
            case .liveTuner(let lease): "liveTuner(\(lease.channel))"
            case .http(let url, let headers): "http(\(Self.redacted(url))\(Self.headerNames(headers)))"
            case .file(let url): "file(\(url.lastPathComponent))"
            case .bytes: "bytes"
            case .hls(let url, let headers): "hls(\(Self.redacted(url))\(Self.headerNames(headers)))"
            case .dash(let url): "dash(\(Self.redacted(url)))"
            }
        }

        public var debugDescription: String { description }

        /// The redacted description only, so `dump()` never reaches a URL, a header value or the tuner lease.
        public var customMirror: Mirror {
            Mirror(self, children: ["redacted": description])
        }

        static func redacted(_ url: URL) -> String {
            let scheme = url.scheme ?? "?"
            guard let host = url.host() else { return "\(scheme):…" }
            return "\(scheme)://\(host)/…"
        }

        static func headerNames(_ headers: [String: String]) -> String {
            headers.isEmpty ? "" : ", headers: [\(headers.keys.sorted().joined(separator: ", "))]"
        }
    }

    public var transport: Transport
    public var container: ContainerHint
    public var codecs: CodecHints?
    /// No end; no seeking beyond the buffer.
    public var isLive: Bool
    /// A recording that is still being written.
    public var isGrowing: Bool
    /// Non-nil exactly when `isGrowing`.
    public var growthMonitor: (any GrowthMonitor)?
    public var start: StartPosition
    /// The tuner, security scope or record-engine session to release when playback stops.
    public var lease: (any PlaybackLease)?

    public init(
        transport: Transport,
        container: ContainerHint = .unknown,
        codecs: CodecHints? = nil,
        isLive: Bool = false,
        isGrowing: Bool = false,
        growthMonitor: (any GrowthMonitor)? = nil,
        start: StartPosition = .beginning,
        lease: (any PlaybackLease)? = nil
    ) {
        self.transport = transport
        self.container = container
        self.codecs = codecs
        self.isLive = isLive
        self.isGrowing = isGrowing
        self.growthMonitor = growthMonitor
        self.start = start
        self.lease = lease
    }

    public var description: String {
        "PlaybackDescriptor(\(transport), container: \(container.rawValue), live: \(isLive), growing: \(isGrowing))"
    }

    public var debugDescription: String { description }

    /// Redacted children: the transport's own redacted mirror, and only the type names of the lease and the
    /// growth monitor, whose own fields may name a file, a session or a device.
    public var customMirror: Mirror {
        Mirror(self, children: [
            "transport": transport,
            "container": container,
            "codecs": codecs as Any,
            "isLive": isLive,
            "isGrowing": isGrowing,
            "growthMonitor": growthMonitor.map { String(describing: type(of: $0)) } as Any,
            "start": start,
            "lease": lease.map { String(describing: type(of: $0)) } as Any
        ], displayStyle: .struct)
    }
}

/// Where playback starts. In-progress recordings default to `.beginning`; `.liveEdge` is "Go Live"; `.resume` is
/// offered only when a saved position exists.
public nonisolated enum StartPosition: Hashable, Codable, Sendable {
    case beginning
    case resume(Duration)
    case liveEdge
}

/// What the player asks a source for.
public nonisolated struct PlaybackRequest: Hashable, Sendable {
    public nonisolated enum Purpose: Hashable, Sendable {
        /// The stream the user explicitly started.
        case watch
        /// A multi-view tile; tuner sources check for a free tuner (after the reserve) first.
        case tile
    }

    /// Nil lets the source choose: the live edge for live TV, the beginning for recordings.
    public var start: StartPosition?
    public var purpose: Purpose
    /// The multi-view tile asking, by its stable identity. Tuner sources hold one subscription per tile (and one for
    /// the single-view player when nil), so a tile's channel change or reconnect never ends another tile's stream.
    public var tileID: UUID?
    /// Open a live channel as a whole multiplex shared with other channels on its frequency (the tile planner
    /// placed it there, or a re-tune makes room). Sources without shared tuners ignore it.
    public var prefersSharedTuner: Bool

    public init(start: StartPosition? = nil, purpose: Purpose = .watch, tileID: UUID? = nil,
                prefersSharedTuner: Bool = false) {
        self.start = start
        self.purpose = purpose
        self.tileID = tileID
        self.prefersSharedTuner = prefersSharedTuner
    }
}
