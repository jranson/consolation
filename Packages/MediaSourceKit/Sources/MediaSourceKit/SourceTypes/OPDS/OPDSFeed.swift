import Foundation

/// An OPDS 2.0 feed (`application/opds+json`): navigation, publications and groups (shelves). Read leniently:
/// unknown members are ignored, and a malformed entry is dropped rather than failing the feed.
public nonisolated struct OPDSFeed: Hashable, Sendable, Decodable {
    public static let mediaType = "application/opds+json"

    public var title: String
    /// The profiles the feed declares (`metadata.conformsTo`).
    public var conformsTo: [String]
    public var numberOfItems: Int?
    public var links: [OPDSLink]
    public var navigation: [OPDSLink]
    public var publications: [OPDSPublication]
    public var groups: [OPDSGroup]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: JSONKey.self)
        let metadata = container.nested("metadata")
        title = metadata?.string("title") ?? ""
        conformsTo = metadata?.strings("conformsTo") ?? []
        numberOfItems = metadata?.integer("numberOfItems")
        links = container.array("links", of: OPDSLink.self)
        navigation = container.array("navigation", of: OPDSLink.self)
        publications = container.array("publications", of: OPDSPublication.self)
        groups = container.array("groups", of: OPDSGroup.self)
    }

    /// The next page's link, when the feed is paged.
    public var next: OPDSLink? { links.first { $0.rels.contains("next") } }
}

/// A shelf in a feed: its own title, and navigation or publications.
public nonisolated struct OPDSGroup: Hashable, Sendable, Decodable {
    public var title: String
    public var links: [OPDSLink]
    public var navigation: [OPDSLink]
    public var publications: [OPDSPublication]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: JSONKey.self)
        title = container.nested("metadata")?.string("title") ?? ""
        links = container.array("links", of: OPDSLink.self)
        navigation = container.array("navigation", of: OPDSLink.self)
        publications = container.array("publications", of: OPDSPublication.self)
    }

    /// The feed the whole shelf comes from (`self`), when it names one.
    public var selfLink: OPDSLink? { links.first { $0.rels.contains("self") } }
}

/// A Readium Web Publication Manifest link object. Only `href` is required.
public nonisolated struct OPDSLink: Hashable, Sendable, Decodable {
    public var href: String
    /// The full media type, parameters included (`video/mp4; codecs="avc1.640028,mp4a.40.2"`).
    public var type: String?
    public var title: String?
    public var rels: [String]
    public var templated: Bool
    public var width: Int?
    public var height: Int?
    /// Kilobits per second.
    public var bitrate: Double?
    /// Seconds.
    public var duration: Double?
    /// Bytes.
    public var size: Int64?
    public var alternates: [OPDSLink]

    public init(href: String, type: String? = nil, title: String? = nil, rels: [String] = [], templated: Bool = false,
                width: Int? = nil, height: Int? = nil, bitrate: Double? = nil, duration: Double? = nil,
                size: Int64? = nil, alternates: [OPDSLink] = []) {
        self.href = href
        self.type = type
        self.title = title
        self.rels = rels
        self.templated = templated
        self.width = width
        self.height = height
        self.bitrate = bitrate
        self.duration = duration
        self.size = size
        self.alternates = alternates
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: JSONKey.self)
        guard let href = container.string("href"), !href.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no href"))
        }
        self.init(href: href, type: container.string("type"), title: container.string("title"),
                  rels: container.strings("rel"), templated: container.bool("templated") ?? false,
                  width: container.integer("width"), height: container.integer("height"),
                  bitrate: container.number("bitrate"), duration: container.number("duration"),
                  size: container.number("size").flatMap { Int64(exactly: $0.rounded()) },
                  alternates: container.array("alternate", of: OPDSLink.self))
    }

    /// The media type without parameters, lowercased (`video/mp4`).
    public var mediaType: String? {
        type?.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    /// The RFC 6381 `codecs` parameter's entries (`["avc1.640028", "mp4a.40.2"]`).
    public var codecs: [String] {
        guard let type, let range = type.range(of: "codecs=", options: .caseInsensitive) else { return [] }
        let value = type[range.upperBound...].prefix { $0 != ";" }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// `href` resolved against the feed it came from (RFC 3986). Nil for a templated link.
    public func url(relativeTo base: URL) -> URL? {
        guard !templated else { return nil }
        return URL(string: href, relativeTo: base)?.absoluteURL
    }
}
