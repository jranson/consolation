import Foundation

/// An item's artwork slots. Cards prefer a landscape thumb, then a backdrop, then a cropped poster; with none of them
/// the app draws a generated face.
public nonisolated struct Artwork: Hashable, Codable, Sendable {
    public var poster: ArtworkRef?
    public var thumb: ArtworkRef?
    public var backdrop: ArtworkRef?
    public var logo: ArtworkRef?

    public init(poster: ArtworkRef? = nil, thumb: ArtworkRef? = nil, backdrop: ArtworkRef? = nil,
                logo: ArtworkRef? = nil) {
        self.poster = poster
        self.thumb = thumb
        self.backdrop = backdrop
        self.logo = logo
    }

    /// The best image for a landscape card: thumb, then backdrop, then poster.
    public var bestLandscape: ArtworkRef? { thumb ?? backdrop ?? poster }
}

/// Where one image comes from.
public nonisolated enum ArtworkRef: Hashable, Codable, Sendable {
    /// A server image. It names the headers it needs (for example `X-Plex-Token`); their values come from the
    /// credential store when the image loads, so no secret is ever part of an item.
    case remote(URL, headerKeys: Set<String>)
    /// An image next to the media, such as `poster.jpg`.
    case sourceFile(MediaItemID, relativePath: String)
    /// A frame the engine makes lazily at idle time and caches. Never for live channels.
    case generatedFrame(MediaItemID, position: Duration)
    /// A generated face (gradient, title or channel number) seeded by a stable string. No I/O.
    case stylized(seed: String)
}
