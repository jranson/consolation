import Foundation
import HTTPMPEG2Kit
import PlaybackKit

/// What PlaybackKit's engines accept today, produced by `PlaybackInputMapper`.
///
/// Until PlaybackKit takes one input type, this mirrors the engines' real initializers:
/// `TransportStreamEngine(makeSource:timeShift:)` and `AVPlayerEngine(url:kind:requestHeaders:)`.
public nonisolated enum EngineInput: Sendable {
    /// Raw MPEG-TS through our own demuxer.
    case transportStream(TransportStreamFeed)
    /// HLS, DASH (translated to HLS) and progressive MP4/MOV through AVPlayer.
    case avPlayer(AVPlayerInput)
}

/// AVPlayer's input: the URL, how to load it, the headers for every request, and where a growing stream starts.
public nonisolated struct AVPlayerInput: Hashable, Sendable {
    public let url: URL
    public let kind: AVPlayerEngine.InputKind
    public let headers: [String: String]
    /// A recording still being written (an HLS EVENT playlist) opens at its first segment, not the live edge.
    public let startsAtBeginning: Bool

    init(url: URL, kind: AVPlayerEngine.InputKind, headers: [String: String] = [:], startsAtBeginning: Bool = false) {
        self.url = url
        self.kind = kind
        self.headers = headers
        self.startsAtBeginning = startsAtBeginning
    }
}

/// The TS engine's input: a byte source per connection attempt.
public nonisolated struct TransportStreamFeed: Sendable {
    public nonisolated enum Growth: Hashable, Sendable {
        /// No end: a tuner or a live stream.
        case live
        case growingFile
        case complete
    }

    public let growth: Growth
    /// The program the first connection selects from the PAT, or nil for the first (and, for program streams, only)
    /// program. For a live channel each connection's `ByteSource.programNumber` is authoritative: a reconnect may
    /// land on a program stream or another multiplex.
    public let programNumber: Int?
    /// The channel, when the bytes come from the tuner broker. A host that shares channels between devices keys
    /// its relay lookups on it.
    public let channel: ChannelKey?
    private let factory: @Sendable (_ expectsRelease: Bool) -> any ByteSource

    init(growth: Growth, programNumber: Int?, channel: ChannelKey?,
         factory: @escaping @Sendable (_ expectsRelease: Bool) -> any ByteSource) {
        self.growth = growth
        self.programNumber = programNumber
        self.channel = channel
        self.factory = factory
    }

    /// The source for the next connection attempt. The engine calls it once per attempt (first open and every
    /// reconnect); each source owns exactly one connection, so one tuner.
    /// - Parameter expectsRelease: a tuner held for us elsewhere is being freed, so a busy answer in the next
    ///   moment is retried once (tuner sharing).
    public func makeSource(expectsRelease: Bool = false) -> any ByteSource {
        factory(expectsRelease)
    }
}

extension EngineInput {
    /// The engine for this input, not yet started.
    @MainActor
    public func makeEngine(
        timeShift: TimeShiftConfiguration = TimeShiftConfiguration(),
        avPlayerConfiguration: AVPlayerEngine.Configuration = AVPlayerEngine.Configuration(),
        preferredLanguage: String = "eng"
    ) -> any PlaybackEngine {
        switch self {
        case .transportStream(let feed):
            TransportStreamEngine(makeSource: { feed.makeSource() }, timeShift: timeShift,
                                  preferredLanguage: preferredLanguage)
        case .avPlayer(let input):
            AVPlayerEngine(url: input.url, kind: input.kind,
                           configuration: input.configured(avPlayerConfiguration), requestHeaders: input.headers)
        }
    }
}

extension AVPlayerInput {
    /// The host's configuration with this input's start.
    func configured(_ configuration: AVPlayerEngine.Configuration) -> AVPlayerEngine.Configuration {
        var configured = configuration
        configured.startsAtBeginning = startsAtBeginning
        return configured
    }
}
