import Foundation

/// Bullpen's own vocabulary: link relations, problem types and terms under `https://centennialoss.org/bullpen/`.
/// These are names, never fetched.
public nonisolated enum BullpenVocabulary {
    public static let namespace = "https://centennialoss.org/bullpen/"
    public static let bonjourType = "_bullpen._tcp"
    /// The port a server listens on unless configured otherwise.
    public static let defaultPort = 7992

    public static func relation(_ name: String) -> String {
        namespace + "rel/" + name
    }

    public static let channels = relation("channels")
    public static let library = relation("library")
    public static let recordings = relation("recordings")
    public static let events = relation("events")
    public static let oidcIssuer = relation("oidc-issuer")
    public static let serviceMeta = "service-meta"
}

/// `GET /api/v1/server`: the server's identity and how it signs in.
public nonisolated struct BullpenServerInfo: Hashable, Sendable, Decodable {
    public nonisolated struct Auth: Hashable, Sendable, Decodable {
        public var required: Bool
        public var issuer: String?
    }

    /// `bullpen:<uuid>`, the same as the Bonjour TXT key `id`: the source's identity.
    public var id: String
    public var name: String
    public var version: String?
    public var auth: Auth?

    /// The source this server is. An id without the `bullpen:` prefix (a TXT record's bare UUID) gets it.
    public var sourceID: SourceID {
        SourceID.bullpen(serverID: id)
    }
}

/// `GET /api/v1/channels`: schema.org `BroadcastChannel`s in guide-number order.
public nonisolated struct BullpenChannelList: Sendable, Decodable {
    public var channels: [BullpenChannel]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: JSONKey.self)
        channels = container.array("channels", of: BullpenChannel.self)
    }
}

public nonisolated struct BullpenChannel: Hashable, Sendable, Decodable {
    public nonisolated struct Link: Hashable, Sendable, Decodable {
        public var rel: String?
        public var href: String
        public var type: String?
    }

    /// `bullpen:ch/antenna-9-1`.
    public var identifier: String
    public var name: String?
    /// The guide number, `9.1`.
    public var number: String
    public var lineupSource: String?
    public var callSign: String?
    public var isHidden: Bool
    public var links: [Link]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: JSONKey.self)
        guard let identifier = container.string("identifier"), let number = container.string("broadcastChannelId")
        else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no channel"))
        }
        self.identifier = identifier
        self.number = number
        name = container.string("name")
        lineupSource = container.string("lineupSource")
        callSign = container.string("callSign")
        isHidden = container.bool("hidden") ?? false
        links = container.array("links", of: Link.self)
    }

    /// The stream to play: HLS, else the MPEG-TS passthrough, else DASH.
    public func streamLink() -> Link? {
        let streams = links.filter { $0.rel == "alternate" }
        for type in ["application/vnd.apple.mpegurl", "video/mp2t", "application/dash+xml"] {
            if let link = streams.first(where: { OPDSLink(href: $0.href, type: $0.type).mediaType == type }) {
                return link
            }
        }
        return nil
    }
}

extension SourceID {
    static let bullpenPrefix = "bullpen:"

    /// A Bullpen server, by the id it reports (`bullpen:<uuid>`), so a changed address is the same source.
    public static func bullpen(serverID: String) -> SourceID {
        SourceID(raw: serverID.hasPrefix(bullpenPrefix) ? serverID : bullpenPrefix + serverID)
    }
}
