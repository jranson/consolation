import Foundation

/// One Home shelf. Its `stableID` names the shelf in settings and in the Etagere (`VideoShelf.id`).
public nonisolated enum HomeShelfKind: Hashable, Codable, Sendable, CustomStringConvertible {
    case favorites
    case liveChannels
    case recordingNow
    case recentRecordings
    case continueWatching
    case quickPlayHistory
    /// A library section the user pinned to Home (a Plex or Jellyfin section, a folder root).
    case library(SourceID, sectionKey: String)

    /// The built-in shelves, in their default order.
    public static let builtIn: [HomeShelfKind] = [
        .favorites, .liveChannels, .recordingNow, .recentRecordings, .continueWatching, .quickPlayHistory
    ]

    private static let libraryPrefix = "library"
    /// `:` separates the library ID's parts and `%` escapes, so both are percent-encoded inside them.
    private static let componentCharacters = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: ":%"))

    /// `favorites`, `liveChannels`, … or `library:<source>:<section>` with both parts percent-encoded, so the
    /// colons inside a `SourceID` (`plex:<id>`) never collide with the separator.
    public var stableID: String {
        switch self {
        case .favorites: "favorites"
        case .liveChannels: "liveChannels"
        case .recordingNow: "recordingNow"
        case .recentRecordings: "recentRecordings"
        case .continueWatching: "continueWatching"
        case .quickPlayHistory: "quickPlayHistory"
        case let .library(source, sectionKey):
            [Self.libraryPrefix, Self.encode(source.raw), Self.encode(sectionKey)].joined(separator: ":")
        }
    }

    /// Parses a `stableID`; nil when it names no shelf. The section key may be empty (a folder source with one
    /// root, for example); the source may not.
    public init?(stableID: String) {
        if let builtIn = Self.builtIn.first(where: { $0.stableID == stableID }) {
            self = builtIn
            return
        }
        let parts = stableID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == Self.libraryPrefix,
              let source = parts[1].removingPercentEncoding, !source.isEmpty,
              let section = parts[2].removingPercentEncoding else { return nil }
        self = .library(SourceID(raw: source), sectionKey: section)
    }

    public var description: String { stableID }

    /// Hidden when it has no items: only the transient shelves, Recording Now and Continue Watching. Every other
    /// enabled shelf, including Quick Play History and pinned library shelves, stays and shows its placeholder.
    public var isHiddenWhenEmpty: Bool {
        switch self {
        case .recordingNow, .continueWatching: true
        case .favorites, .liveChannels, .recentRecordings, .quickPlayHistory, .library: false
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let kind = HomeShelfKind(stableID: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a Home shelf")
        }
        self = kind
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stableID)
    }

    private static func encode(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: componentCharacters) ?? component
    }
}

/// What one source puts on one shelf. A source's latest `[ShelfContribution]` replaces all it contributed before.
public nonisolated struct ShelfContribution: Hashable, Codable, Sendable {
    public var shelf: HomeShelfKind
    public var items: [MediaItem]
    /// Higher ranks come first when several sources feed one shelf; ties keep the sources' order.
    public var rank: Double
    /// When the source last confirmed these items.
    public var freshness: Date
    /// The shelf title, for library shelves (the section's name). Built-in shelves use `HomeShelfMessages`.
    public var title: String?

    public init(shelf: HomeShelfKind, items: [MediaItem], rank: Double = 0, freshness: Date,
                title: String? = nil) {
        self.shelf = shelf
        self.items = items
        self.rank = rank
        self.freshness = freshness
        self.title = title
    }
}

/// One composed Home shelf: MediaItems only. The app maps it to a `VideoShelf` through its `VideoCard` factories.
public nonisolated struct HomeShelf: Identifiable, Hashable, Sendable {
    public let kind: HomeShelfKind
    public var title: String
    public var items: [MediaItem]
    /// One placeholder card's text when `items` is empty, for example "No Live TV source configured".
    public var emptyMessage: String?
    /// A source that feeds this shelf missed its soft timeout: the items are from the snapshot and may be stale.
    public var isUpdating: Bool

    public init(kind: HomeShelfKind, title: String, items: [MediaItem], emptyMessage: String? = nil,
                isUpdating: Bool = false) {
        self.kind = kind
        self.title = title
        self.items = items
        self.emptyMessage = emptyMessage
        self.isUpdating = isUpdating
    }

    public var id: String { kind.stableID }
}
