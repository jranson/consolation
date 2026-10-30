import CryptoKit
import Foundation

/// OPDS entries as `MediaItem`s: publications as videos and recordings, navigation links as folders.
///
/// Keys: `pub:<identifier>` for a publication (`url:<SHA-256 of its first playable href>` without one) and
/// `feed:<path and query>` for a feed. Feed paths name no secret (media grants ride only in media links), and a
/// media URL never becomes a key.
public nonisolated enum OPDSItems {
    public static let publicationPrefix = "pub:"
    public static let feedPrefix = "feed:"
    static let posterRelation = "https://centennialoss.org/bullpen/rel/poster"

    /// The key of a publication, or nil when it has neither an identifier nor a playable link.
    public static func key(for publication: OPDSPublication, base: URL) -> String? {
        if let identifier = publication.metadata.identifier, !identifier.isEmpty {
            return publicationPrefix + identifier
        }
        guard let choice = OPDSPlayback.choice(for: publication, base: base) else { return nil }
        let digest = SHA256.hash(data: Data(choice.url.absoluteString.utf8))
        return MediaItemID.urlKeyPrefix + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The key of a feed: its URL's path and query, so the same feed is the same folder from any page that links it.
    public static func key(forFeed url: URL) -> String {
        let query = url.query(percentEncoded: true).map { "?" + $0 } ?? ""
        return feedPrefix + url.path(percentEncoded: true) + query
    }

    /// A publication as an item. Images load only from hosts `allowsImage` accepts: the app connects only to the
    /// sources the user added, so a catalog's links to other hosts are left out and the card draws its own face.
    public static func item(for publication: OPDSPublication, source: SourceID, base: URL,
                            allowsImage: (URL) -> Bool) -> MediaItem? {
        guard let key = key(for: publication, base: base) else { return nil }
        let metadata = publication.metadata
        let choice = OPDSPlayback.choice(for: publication, base: base)
        let seconds = metadata.duration ?? choice?.link.duration
        return MediaItem(
            id: MediaItemID(source: source, key: key), kind: kind(of: metadata, isPlayable: choice != nil),
            title: metadata.title.isEmpty ? (metadata.seriesName ?? "Untitled") : metadata.title,
            subtitle: metadata.subtitle ?? metadata.seriesName, synopsis: metadata.synopsis,
            artwork: artwork(publication.images, base: base, allowsImage: allowsImage),
            duration: seconds.flatMap { $0.isFinite && $0 > 0 ? Duration.milliseconds(Int64($0 * 1000)) : nil },
            addedAt: metadata.recordedAt ?? metadata.published,
            technical: choice.map { CodecHints(container: $0.container) })
    }

    /// A navigation link as a folder, or nil when it isn't a feed this source can open.
    public static func folder(for link: OPDSLink, source: SourceID, base: URL) -> MediaItem? {
        guard let url = link.url(relativeTo: base), link.mediaType == nil || link.mediaType == OPDSFeed.mediaType else {
            return nil
        }
        return MediaItem(id: MediaItemID(source: source, key: key(forFeed: url)), kind: .folder,
                         title: link.title ?? url.lastPathComponent)
    }

    static func kind(of metadata: OPDSPublicationMetadata, isPlayable: Bool) -> MediaItem.Kind {
        if metadata.inProgress || metadata.recordedAt != nil {
            return .recording(airedAt: metadata.published, recordedAt: metadata.recordedAt,
                              inProgress: metadata.inProgress, channel: metadata.channel?.label)
        }
        switch metadata.kind {
        case .movie:
            let year = metadata.published.map { Calendar(identifier: .gregorian).component(.year, from: $0) }
            return .movie(year: year)
        case .episode:
            return .episode(series: metadata.seriesName ?? metadata.subtitle ?? "", season: metadata.season,
                            episode: metadata.episode, airDate: metadata.published)
        case .series:
            return .series
        case .video:
            return isPlayable ? .clip : .folder
        }
    }

    /// Posters are taller than wide (or say so); anything else is a landscape thumb. The first of each wins.
    static func artwork(_ images: [OPDSLink], base: URL, allowsImage: (URL) -> Bool) -> Artwork {
        var artwork = Artwork()
        for image in images {
            guard let url = image.url(relativeTo: base), allowsImage(url) else { continue }
            let isPoster = image.rels.contains(posterRelation)
                || (image.height ?? 0) > (image.width ?? .max)
            let ref = ArtworkRef.remote(url, headerKeys: [])
            if isPoster {
                if artwork.poster == nil { artwork.poster = ref }
            } else if artwork.thumb == nil {
                artwork.thumb = ref
            }
        }
        return artwork
    }
}
