import Foundation

/// The parts of Plex's `MediaContainer` responses Consolation reads, decoded leniently: every member is optional,
/// unknown members are ignored, and an entry that doesn't decode is dropped rather than failing the response.
nonisolated extension PlexClient {
    struct Envelope: Decodable {
        let container: Container

        init(from decoder: any Decoder) throws {
            let root = try decoder.container(keyedBy: JSONKey.self)
            container = try root.decode(Container.self, forKey: JSONKey("MediaContainer"))
        }
    }

    public nonisolated struct Container: Decodable, Sendable {
        public var machineIdentifier: String?
        public var friendlyName: String?
        public var version: String?
        public var totalSize: Int?
        public var metadata: [Metadata]
        public var sections: [Section]
        public var subscriptions: [Subscription]
        public var grabOperations: [GrabOperation]

        public init(from decoder: any Decoder) throws {
            let json = try decoder.container(keyedBy: JSONKey.self)
            machineIdentifier = json.string("machineIdentifier")
            friendlyName = json.string("friendlyName")
            version = json.string("version")
            totalSize = json.integer("totalSize")
            metadata = json.array("Metadata", of: Metadata.self)
            sections = json.array("Directory", of: Section.self)
            subscriptions = json.array("MediaSubscription", of: Subscription.self)
            grabOperations = json.array("MediaGrabOperation", of: GrabOperation.self)
        }
    }

    /// A library section (`Directory` in `/library/sections/all`).
    public nonisolated struct Section: Decodable, Hashable, Sendable {
        public var key: String
        /// `show`, `movie`, `artist`, `photo`.
        public var type: String
        public var title: String

        public init(from decoder: any Decoder) throws {
            let json = try decoder.container(keyedBy: JSONKey.self)
            guard let key = json.string("key") else { throw PlexClient.missing("key", decoder) }
            self.key = key
            type = json.string("type") ?? ""
            title = json.string("title") ?? key
        }
    }

    /// A show, season, episode or movie.
    public nonisolated struct Metadata: Decodable, Hashable, Sendable {
        public var ratingKey: String
        public var type: String?
        public var title: String?
        public var grandparentTitle: String?
        public var parentTitle: String?
        public var summary: String?
        public var index: Int?
        public var parentIndex: Int?
        public var year: Int?
        public var thumb: String?
        public var art: String?
        /// Milliseconds.
        public var duration: Int?
        /// `2026-10-25`, or `2026-11-01 05:00:00` for an airing.
        public var originallyAvailableAt: String?
        /// Seconds since 1970.
        public var addedAt: Int?
        public var librarySectionID: Int?
        public var media: [Media]?
        /// The channels it aired on (`9.1 KDDD (NBC)`).
        public var channels: [String]

        public init(from decoder: any Decoder) throws {
            let json = try decoder.container(keyedBy: JSONKey.self)
            guard let ratingKey = json.string("ratingKey") ?? json.integer("ratingKey").map(String.init) else {
                throw PlexClient.missing("ratingKey", decoder)
            }
            self.ratingKey = ratingKey
            type = json.string("type")
            title = json.string("title")
            grandparentTitle = json.string("grandparentTitle")
            parentTitle = json.string("parentTitle")
            summary = json.string("summary")
            index = json.integer("index")
            parentIndex = json.integer("parentIndex")
            year = json.integer("year")
            thumb = json.string("thumb")
            art = json.string("art")
            duration = json.integer("duration")
            originallyAvailableAt = json.string("originallyAvailableAt")
            addedAt = json.integer("addedAt")
            librarySectionID = json.integer("librarySectionID")
            let media = json.array("Media", of: Media.self)
            self.media = media.isEmpty ? nil : media
            channels = json.array("Channel", of: Tag.self).compactMap(\.tag)
        }
    }

    public nonisolated struct Media: Decodable, Hashable, Sendable {
        public var container: String?
        public var videoCodec: String?
        public var audioCodec: String?
        public var height: Int?
        /// `dvr` for a recording.
        public var origin: String?
        /// `complete`, or `inprogress` while it records.
        public var mediaGrabStatus: String?
        /// An airing's start and end, seconds since 1970 (grab operations).
        public var beginsAt: Int?
        public var endsAt: Int?
        /// The guide number (`9.1`) and call sign of an airing's channel.
        public var channelVcn: String?
        public var channelCallSign: String?
        public var channelTitle: String?
        public var parts: [Part]?

        public init(from decoder: any Decoder) throws {
            let json = try decoder.container(keyedBy: JSONKey.self)
            container = json.string("container")
            videoCodec = json.string("videoCodec")
            audioCodec = json.string("audioCodec")
            height = json.integer("height")
            origin = json.string("origin")
            mediaGrabStatus = json.string("mediaGrabStatus")
            beginsAt = json.integer("beginsAt")
            endsAt = json.integer("endsAt")
            channelVcn = json.string("channelVcn")
            channelCallSign = json.string("channelCallSign")
            channelTitle = json.string("channelTitle")
            let parts = json.array("Part", of: Part.self)
            self.parts = parts.isEmpty ? nil : parts
        }
    }

    /// One file of a media item. `key` is its bytes on this server (`/library/parts/…`); `file` is its path on the
    /// server's disk, for path mappings.
    public nonisolated struct Part: Decodable, Hashable, Sendable {
        public var key: String?
        public var file: String?
        public var size: Int64?
        public var container: String?

        public init(from decoder: any Decoder) throws {
            let json = try decoder.container(keyedBy: JSONKey.self)
            key = json.string("key")
            file = json.string("file")
            size = json.number("size").flatMap { Int64(exactly: $0.rounded()) }
            container = json.string("container")
        }
    }

    struct Tag: Decodable {
        let tag: String?

        init(from decoder: any Decoder) throws {
            tag = try decoder.container(keyedBy: JSONKey.self).string("tag")
        }
    }

    /// A DVR recording rule.
    public nonisolated struct Subscription: Decodable, Hashable, Sendable {
        public var key: String?
        public var title: String?
        public var targetLibrarySectionID: Int?

        public init(from decoder: any Decoder) throws {
            let json = try decoder.container(keyedBy: JSONKey.self)
            key = json.string("key")
            title = json.string("title")
            targetLibrarySectionID = json.integer("targetLibrarySectionID")
        }
    }

    /// One scheduled, in-progress or finished recording of an airing.
    public nonisolated struct GrabOperation: Decodable, Hashable, Sendable {
        public var id: String
        /// `scheduled`, `inprogress`, `complete`, `postprocessing`, `error`, `cancelled`, `paused`, `inactive`.
        public var status: String?
        public var mediaSubscriptionID: Int?
        public var metadata: Metadata?

        public init(from decoder: any Decoder) throws {
            let json = try decoder.container(keyedBy: JSONKey.self)
            guard let id = json.string("id") else { throw PlexClient.missing("id", decoder) }
            self.id = id
            status = json.string("status")
            mediaSubscriptionID = json.integer("mediaSubscriptionID")
            metadata = try? json.decodeIfPresent(Metadata.self, forKey: JSONKey("Metadata"))
        }
    }

    static func missing(_ member: String, _ decoder: any Decoder) -> DecodingError {
        .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no \(member)"))
    }
}
