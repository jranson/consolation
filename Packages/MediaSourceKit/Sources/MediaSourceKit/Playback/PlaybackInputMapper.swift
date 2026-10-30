import Foundation
import HTTPMPEG2Kit
import PlaybackKit

/// Turns a `PlaybackDescriptor` into what PlaybackKit's engines accept today.
///
/// | Descriptor | Input |
/// |---|---|
/// | `.liveTuner` | `.transportStream`: the lease's open subscription, then a new broker subscription per reconnect |
/// | `.http`, MPEG-TS | `.transportStream` over GETs (`HTTPByteSource`, or `RawHTTPByteSource` for plain http to a host
///   outside the local network): one for a live stream, range requests to seek a recording |
/// | `.file`, MPEG-TS | `.transportStream` read from the file (`FileByteSource`), seekable |
/// | `.hls`, `.dash` | `.avPlayer(.hls)`, `.avPlayer(.dash)` |
/// | `.http` or `.file`, MP4/MOV or unknown | `.avPlayer(.file)` |
///
/// Request headers (a server's token) go with every request of either engine. They are refused for plain http to a
/// host outside the local network, so a secret never crosses the internet unencrypted.
///
/// A growing HLS or DASH recording (an EVENT playlist, a dynamic MPD) plays in AVPlayer, which follows it, from its
/// beginning. What the engines can't take yet throws a `PlaybackMappingError` instead of playing wrongly:
/// `ByteRangeSource`s, other growing files, resuming at a saved position, and MKV. A live channel on a shared multiplex plays: each
/// connection's `ByteSource` names the program the engine selects from the PAT.
public nonisolated enum PlaybackInputMapper {
    public static func input(for descriptor: PlaybackDescriptor) throws(PlaybackMappingError) -> EngineInput {
        if case .resume = descriptor.start { throw .startPosition(descriptor.start) }
        if descriptor.isGrowing, !followsGrowth(descriptor.transport) { throw .growingFile }
        let fromBeginning = descriptor.isGrowing && descriptor.start == .beginning
        switch descriptor.transport {
        case .liveTuner(let lease):
            return liveInput(lease)
        case let .http(url, headers):
            try checkHeaders(headers, for: url)
            return try urlInput(url, headers: headers, descriptor: descriptor)
        case .file(let url):
            return try urlInput(url, headers: [:], descriptor: descriptor)
        case .bytes:
            throw .byteRangeSource
        case let .hls(url, headers):
            try checkHeaders(headers, for: url)
            return .avPlayer(AVPlayerInput(url: url, kind: .hls, headers: headers, startsAtBeginning: fromBeginning))
        case .dash(let url):
            return .avPlayer(AVPlayerInput(url: url, kind: .dash, startsAtBeginning: fromBeginning))
        }
    }

    /// AVPlayer rereads HLS and DASH manifests, so it follows a recording as it grows.
    private static func followsGrowth(_ transport: PlaybackDescriptor.Transport) -> Bool {
        switch transport {
        case .hls, .dash: true
        default: false
        }
    }

    /// Headers carry secrets: never over plain http off the local network.
    private static func checkHeaders(_ headers: [String: String], for url: URL) throws(PlaybackMappingError) {
        if !headers.isEmpty, RawHTTPByteSource.isNeeded(for: url) { throw .insecureRequestHeaders }
    }

    /// A tuner lease as the TS engine's source. The first connection reads the open subscription; each reconnect
    /// subscribes again in the lease's slot, exactly as the app's engine factory does for a channel, and the lease
    /// follows it. `programNumber` is the first connection's program (nil for a program stream); the engine takes
    /// each connection's own from its `ByteSource`, since a reconnect may land on another upstream.
    static func liveInput(_ lease: TunerLease) -> EngineInput {
        .transportStream(TransportStreamFeed(
            growth: .live, programNumber: lease.programNumber, channel: lease.channel,
            factory: { lease.makeSource(expectsRelease: $0) }))
    }

    private static func urlInput(_ url: URL, headers: [String: String], descriptor: PlaybackDescriptor)
        throws(PlaybackMappingError) -> EngineInput {
        switch resolvedContainer(descriptor.container, url: url) {
        case .mpegTS:
            return .transportStream(transportStreamFeed(url, headers: headers, isLive: descriptor.isLive))
        case .hls:
            return .avPlayer(AVPlayerInput(url: url, kind: .hls, headers: headers))
        case .dash:
            return .avPlayer(AVPlayerInput(url: url, kind: .dash, headers: headers))
        case .mp4, .mov, .unknown:
            // As in Quick Play today: an unrecognized URL gets a try in AVPlayer, which reports what it can't play.
            return .avPlayer(AVPlayerInput(url: url, kind: .file, headers: headers))
        case .mkv:
            throw .container(.mkv)
        }
    }

    /// The hint when the source gave one, otherwise PlaybackKit's URL classification (extension, query, tuner path).
    static func resolvedContainer(_ hint: ContainerHint, url: URL) -> ContainerHint {
        guard hint == .unknown else { return hint }
        switch URLKindDetector.detect(url) {
        case .transportStream: return .mpegTS
        case .hls: return .hls
        case .dash: return .dash
        case .progressive: return .mp4
        case .unknown: return .unknown
        }
    }

    /// A file read from disk, or GETs through URLSession where App Transport Security allows it. A live stream
    /// opens one GET per connection attempt; a recording plays to its end and seeks with range requests (the
    /// engine learns which from the source's `isFinite`).
    private static func transportStreamFeed(_ url: URL, headers: [String: String], isLive: Bool)
        -> TransportStreamFeed {
        if url.isFileURL {
            return TransportStreamFeed(growth: .complete, programNumber: nil, channel: nil) { _ in
                FileByteSource(url: url)
            }
        }
        let needsRawClient = headers.isEmpty && RawHTTPByteSource.isNeeded(for: url)
        return TransportStreamFeed(growth: isLive ? .live : .complete, programNumber: nil, channel: nil) { _ in
            if needsRawClient { return RawHTTPByteSource(url: url) }
            return HTTPByteSource(url: url, headers: headers)
        }
    }
}

/// A descriptor PlaybackKit can't play yet. Each case names the engine feature that is missing.
public nonisolated enum PlaybackMappingError: Error, Hashable, Sendable {
    /// The source wants request headers (a token) sent over plain http to a host outside the local network.
    case insecureRequestHeaders
    /// No engine input reads a `ByteRangeSource` yet (in-app SMB and NFS).
    case byteRangeSource
    /// The TS engine can't follow a growing recording yet.
    case growingFile
    /// The TS engine can't select this program from the PAT. No longer produced for live channels (each connection
    /// names its program through `ByteSource.programNumber`); kept for sources without program selection.
    case programSelection(Int)
    /// Neither engine can start at a saved position yet. Ask again with `.beginning`.
    case startPosition(StartPosition)
    /// No engine plays this container.
    case container(ContainerHint)

    /// A user-presentable error for the player's failure state.
    public var playbackError: PlaybackError {
        PlaybackError(kind: .unsupportedFormat, title: message, domain: "MediaSourceKit")
    }

    public var message: String {
        switch self {
        case .insecureRequestHeaders: "This server needs a secure (https) connection to play from it."
        case .byteRangeSource: "Playing from this source isn't supported yet."
        case .growingFile: "Recordings in progress can't be played yet."
        case .programSelection: "This channel can't be played while it shares a tuner."
        case .startPosition: "Resuming isn't supported for this video yet."
        case .container: "This video format isn't supported."
        }
    }
}
