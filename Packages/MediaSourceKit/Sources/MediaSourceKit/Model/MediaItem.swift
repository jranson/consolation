import Foundation

/// One browsable or playable thing from a source: a live channel, a recording, a movie, a folder.
///
/// Items hold no secrets: artwork names the headers it needs but never their values, and a URL that could carry
/// a token never appears in an item (Quick Play items are keyed by a hash). That keeps items safe to cache in the
/// Home snapshot and to log.
public nonisolated struct MediaItem: Identifiable, Hashable, Codable, Sendable {
    public nonisolated enum Kind: Hashable, Codable, Sendable {
        case channel(number: String, callSign: String, isHD: Bool, isFavorite: Bool)
        case recording(airedAt: Date?, recordedAt: Date?, inProgress: Bool, channel: String?)
        case movie(year: Int?)
        case episode(series: String, season: Int?, episode: Int?, airDate: Date?)
        case series
        case season(Int)
        case folder
        case file
        case clip
    }

    public let id: MediaItemID
    public var kind: Kind
    public var title: String
    public var subtitle: String?
    public var synopsis: String?
    public var artwork: Artwork
    public var duration: Duration?
    public var addedAt: Date?
    /// Local first; server progress only when the user turned on watch-state sync.
    public var progress: PlaybackProgress?
    /// Provider identifiers, for example `"tmdb": "603"` or `"imdb": "tt0133093"`.
    public var providerIDs: [String: String]
    /// Container and codecs, when known.
    public var technical: CodecHints?

    public init(
        id: MediaItemID,
        kind: Kind,
        title: String,
        subtitle: String? = nil,
        synopsis: String? = nil,
        artwork: Artwork = Artwork(),
        duration: Duration? = nil,
        addedAt: Date? = nil,
        progress: PlaybackProgress? = nil,
        providerIDs: [String: String] = [:],
        technical: CodecHints? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.synopsis = synopsis
        self.artwork = artwork
        self.duration = duration
        self.addedAt = addedAt
        self.progress = progress
        self.providerIDs = providerIDs
        self.technical = technical
    }

    /// The stable card identity, `"<SourceID.raw>:<key>"`.
    public var cardID: String { id.cardID }

    /// True for a live channel marked as a favorite on its device (`"Favorite":1`).
    public var isDeviceFavorite: Bool {
        if case .channel(_, _, _, let isFavorite) = kind { return isFavorite }
        return false
    }
}
