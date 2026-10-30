//
//  PlaybackEngine.swift
//  PlaybackKit
//
//  The contract every engine implements (AVPlayerEngine for HLS/MP4/DASH, TransportStreamEngine for raw MPEG-TS).
//  The host app only sees this protocol, so it can switch engines per stream and show any engine's layer.
//

import Foundation
import Observation
import QuartzCore

/// What an engine is doing right now. Engines publish changes on the main actor.
nonisolated public enum PlaybackState: Equatable, Sendable {
    case idle
    case connecting
    case buffering
    case playing
    case paused
    case ended
    case failed(PlaybackError)

    public var isActive: Bool {
        switch self {
        case .connecting, .buffering, .playing, .paused: true
        case .idle, .ended, .failed: false
        }
    }
}

/// A typed, user-presentable playback failure. `detail` is for Copy Details and logs; it never contains secrets.
nonisolated public struct PlaybackError: Error, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case network
        case source
        case unsupportedFormat
        case decoder
        case renderer
        case cancelled
    }

    public let kind: Kind
    public let title: String
    public let detail: String
    public let domain: String?
    public let code: Int?

    public init(kind: Kind, title: String, detail: String = "", domain: String? = nil, code: Int? = nil) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.domain = domain
        self.code = code
    }

    /// Wraps any error, keeping its domain and code for Copy Details.
    public init(kind: Kind, title: String, underlying: any Error) {
        let nsError = underlying as NSError
        self.init(kind: kind, title: title, detail: nsError.localizedDescription, domain: nsError.domain,
                  code: nsError.code)
    }
}

/// Basic facts about the playing stream, for the stats overlay and Now Playing.
nonisolated public struct PlaybackStreamInfo: Equatable, Sendable {
    public var videoCodec: String?
    public var audioCodec: String?
    public var width: Int?
    public var height: Int?
    public var frameRate: Double?
    public var isInterlaced: Bool?
    public var audioChannels: Int?
    public var audioLanguage: String?
    public var isLive: Bool
    /// The stream's audio is in a codec no Apple platform decodes (for example "AC-4" on ATSC 3.0 channels), so it
    /// plays without sound: show "no audio (AC-4)". `audioCodec` is nil then.
    public var unsupportedAudioCodec: String?

    public init(videoCodec: String? = nil, audioCodec: String? = nil, width: Int? = nil, height: Int? = nil,
                frameRate: Double? = nil, isInterlaced: Bool? = nil, audioChannels: Int? = nil,
                audioLanguage: String? = nil, isLive: Bool = false, unsupportedAudioCodec: String? = nil) {
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.isInterlaced = isInterlaced
        self.audioChannels = audioChannels
        self.audioLanguage = audioLanguage
        self.isLive = isLive
        self.unsupportedAudioCodec = unsupportedAudioCodec
    }
}

/// One playing stream. Engines are main-actor objects whose pipelines run off the main actor.
public protocol PlaybackEngine: AnyObject, Observable {
    /// Current state; observable.
    var state: PlaybackState { get }
    /// Facts about the stream once known; observable.
    var streamInfo: PlaybackStreamInfo { get }
    /// The layer that shows the video; it never changes for the engine's life. Hosts show `displayView`, never the
    /// layer directly.
    var displayLayer: CALayer { get }
    /// The view whose backing layer is `displayLayer`. The host adds it as a subview and sizes it; system Picture in
    /// Picture borrows it while active.
    var displayView: PlatformView { get }
    /// Audio mute without stopping the stream.
    var isMuted: Bool { get set }
    /// Starts connecting and playing. Calling it twice has no effect.
    func start()
    /// Pauses presentation. Live engines keep receiving into their buffer.
    func pause()
    /// Resumes after `pause()`.
    func resume()
    /// Stops for good and releases every network connection (and so any tuner) promptly.
    func stop()

    // Multi-view (TilePresentation.swift has single-stream defaults).
    /// How much of the stream is decoded and shown.
    var decodeTier: DecodeTier { get }
    func setDecodeTier(_ tier: DecodeTier)
    /// Whether the engine's audio plays. A silent engine skips audio decoding; turning audio back on starts it at
    /// the clock's current time, without a gap where the stream allows. Independent of `isMuted` (the user's mute).
    var playsAudio: Bool { get set }
    /// Audio volume from 0 to 1, for crossfades between tiles. Independent of `isMuted`.
    var volume: Float { get set }

    // Timeline (PlaybackTimeline.swift has defaults for engines that can't seek).
    /// The reachable range and the position now, or nil when the stream can't seek (yet). Cheap enough to call a few
    /// times a second; not observable (hosts poll it while a scrubber is on screen).
    func timeline() -> PlaybackTimeline?
    /// Moves playback to `position` (a point within `timeline().range`; clamped). Keeps the paused state.
    func seek(toPosition position: Double)
}

/// Live numbers for the stats overlay, refreshed about once a second while playing.
nonisolated public struct PlaybackDiagnostics: Equatable, Sendable {
    public var secondsBehindLive: Double = 0
    public var audioSecondsBuffered: Double = 0
    public var videoSecondsBuffered: Double = 0
    public var framesShown: Int = 0
    public var framesDropped: Int = 0
    public var bytesPerSecond: Double = 0
    public var reconnects: Int = 0

    public init() {}
}

/// Extra controls for live streams with a time-shift buffer.
public protocol LivePlaybackControlling: AnyObject {
    /// How far playback trails the live edge, in seconds (0 when live).
    var diagnostics: PlaybackDiagnostics { get }
    /// Drops the time-shift backlog and plays from (nearly) live.
    func jumpToLive()
    /// Moves within the time-shift buffer by about `seconds` (negative goes back).
    func skip(seconds: Double)
}

/// One selectable audio track.
nonisolated public struct AudioTrackOption: Identifiable, Equatable, Sendable {
    public let id: Int
    public let language: String?
    public let codec: String

    public init(id: Int, language: String?, codec: String) {
        self.id = id
        self.language = language
        self.codec = codec
    }

    /// "English (AC-3)", "Spanish (AC-3)" or "Track 2 (AC-3)".
    public var displayName: String {
        let name = language.flatMap { Locale.current.localizedString(forLanguageCode: $0) } ?? "Track \(id)"
        return "\(name) (\(codec))"
    }
}

/// Engines that decode closed captions (CEA-608 in live MPEG-TS).
public protocol CaptionProviding: AnyObject {
    /// What should be on screen now for the selected service (empty when nothing is captioned).
    var captionScreen: CaptionScreen { get }
    /// Services that have carried captions so far, for a Subtitles menu.
    var availableCaptionServices: [CaptionService] { get }
    var captionService: CaptionService { get }
    func selectCaptionService(_ service: CaptionService)
}

/// Engines that can switch audio tracks.
public protocol AudioTrackSelecting: AnyObject {
    var audioTracks: [AudioTrackOption] { get }
    var selectedAudioTrackID: Int? { get }
    func selectAudioTrack(id: Int)
}

/// One subtitle or caption rendition an engine can show (HLS and file content through AVPlayer).
nonisolated public struct SubtitleOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    /// Closed captions (for the deaf and hard of hearing) rather than translation subtitles.
    public let isClosedCaptions: Bool

    public init(id: String, displayName: String, isClosedCaptions: Bool) {
        self.id = id
        self.displayName = displayName
        self.isClosedCaptions = isClosedCaptions
    }
}

/// Engines whose subtitles are chosen from renditions and drawn by the system, styled by the user's caption
/// settings (AVPlayer media selection).
public protocol SubtitleSelecting: AnyObject {
    var subtitleOptions: [SubtitleOption] { get }
    /// The rendition showing, or nil when subtitles are off.
    var selectedSubtitleID: String? { get }
    /// Shows a rendition, or turns subtitles off with nil.
    func selectSubtitle(id: String?)
}
