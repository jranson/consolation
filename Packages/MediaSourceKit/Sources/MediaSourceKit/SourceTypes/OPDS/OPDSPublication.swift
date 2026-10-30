import Foundation

/// A publication: one video, with its metadata, its links (versions to play, related resources) and its images.
public nonisolated struct OPDSPublication: Hashable, Sendable, Decodable {
    public var metadata: OPDSPublicationMetadata
    public var links: [OPDSLink]
    public var images: [OPDSLink]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: JSONKey.self)
        guard let metadata = container.nested("metadata") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no metadata"))
        }
        self.metadata = OPDSPublicationMetadata(metadata)
        links = container.array("links", of: OPDSLink.self)
        images = container.array("images", of: OPDSLink.self)
    }

    /// The first link with `relation`.
    public func link(_ relation: String) -> OPDSLink? {
        links.first { $0.rels.contains(relation) }
    }
}

/// The metadata Consolation reads: RWPM's core terms, schema.org's `@type`, and the video profile's terms.
public nonisolated struct OPDSPublicationMetadata: Hashable, Sendable {
    public nonisolated enum Kind: Hashable, Sendable {
        case movie
        case episode
        case series
        case video
    }

    public var kind: Kind
    public var identifier: String?
    public var title: String
    public var subtitle: String?
    public var synopsis: String?
    public var published: Date?
    public var duration: Double?
    public var seriesName: String?
    /// The episode number (`belongsTo.series.position`).
    public var episode: Int?
    public var season: Int?
    /// The profile's `inProgress`: a recording still being written.
    public var inProgress: Bool
    public var partial: Bool
    public var recordedAt: Date?
    public var channel: OPDSVideoProfile.Channel?

    init(_ container: KeyedDecodingContainer<JSONKey>) {
        kind = Self.kind(container.string("@type"))
        identifier = container.string("identifier")
        title = container.string("title") ?? ""
        subtitle = container.string("subtitle")
        synopsis = container.string("description")
        published = container.date("published")
        duration = container.number("duration")
        let series = container.nested("belongsTo")?.array("series", of: OPDSSeriesReference.self).first
        seriesName = series?.name
        episode = series?.position
        let profile = OPDSVideoProfile.self
        season = container.integer(profile.term("season"))
        inProgress = container.bool(profile.term("inProgress")) ?? false
        partial = container.bool(profile.term("partial")) ?? false
        recordedAt = container.date(profile.term("recordedAt"))
        channel = container.nested(profile.term("channel")).map(OPDSVideoProfile.Channel.init)
    }

    /// `@type` as a schema.org type, with or without the scheme (`http://schema.org/Movie`, `schema:Movie`).
    static func kind(_ type: String?) -> Kind {
        let name = type?.split(whereSeparator: { "/:#".contains($0) }).last.map(String.init) ?? ""
        switch name {
        case "Movie": return .movie
        case "TVEpisode", "Episode": return .episode
        case "TVSeries", "TVSeason": return .series
        default: return .video
        }
    }
}

/// `belongsTo.series[]`.
nonisolated struct OPDSSeriesReference: Decodable {
    let name: String?
    let position: Int?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: JSONKey.self)
        name = container.string("name")
        position = container.integer("position")
    }
}

/// The OPDS video profile: terms for recordings and video facts that OPDS lacks, each keyed by the profile URI plus
/// `#` and its name. App-agnostic; any producer may use it.
public nonisolated enum OPDSVideoProfile {
    public static let uri = "https://centennialoss.org/bullpen/ns/video"

    static func term(_ name: String) -> String {
        uri + "#" + name
    }

    /// The channel a recording came from.
    public nonisolated struct Channel: Hashable, Sendable {
        public var identifier: String?
        public var name: String?
        /// The guide number (`9.1`).
        public var number: String?
        public var callSign: String?

        init(_ container: KeyedDecodingContainer<JSONKey>) {
            identifier = container.string("identifier")
            name = container.string("name")
            number = container.string("broadcastChannelId")
            callSign = container.string("callSign")
        }

        /// `9.1 KDDD`, or whichever parts it has.
        public var label: String? {
            let parts = [number, callSign ?? name].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }
}
