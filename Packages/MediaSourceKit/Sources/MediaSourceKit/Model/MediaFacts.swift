import Foundation

/// How far the user got in an item.
public nonisolated struct PlaybackProgress: Hashable, Codable, Sendable {
    public var position: Duration
    public var duration: Duration?
    public var updatedAt: Date
    /// Watched to the end (or marked watched); finished items leave Continue Watching.
    public var isFinished: Bool

    public init(position: Duration, duration: Duration? = nil, updatedAt: Date, isFinished: Bool = false) {
        self.position = position
        self.duration = duration
        self.updatedAt = updatedAt
        self.isFinished = isFinished
    }

    /// The position as a fraction of the duration (0...1), or nil when the duration is unknown.
    public var fraction: Double? {
        guard let duration, duration > .zero else { return nil }
        return min(max(position / duration, 0), 1)
    }
}

/// The container a descriptor or item is believed to use. `.unknown` means "decide from the URL".
public nonisolated enum ContainerHint: String, Hashable, Codable, Sendable {
    case mpegTS
    case mp4
    case mov
    case mkv
    case hls
    case dash
    case unknown
}

public nonisolated enum VideoCodecHint: String, Hashable, Codable, Sendable {
    case mpeg2
    case h264
    case hevc
    case other
}

public nonisolated enum AudioCodecHint: String, Hashable, Codable, Sendable {
    case ac3
    case eac3
    case aac
    case ac4
    case mpeg
    case other
}

/// Container and codecs, when the source knows them.
public nonisolated struct CodecHints: Hashable, Codable, Sendable {
    public var container: ContainerHint?
    public var video: VideoCodecHint?
    public var audio: AudioCodecHint?

    public init(container: ContainerHint? = nil, video: VideoCodecHint? = nil, audio: AudioCodecHint? = nil) {
        self.container = container
        self.video = video
        self.audio = audio
    }
}
