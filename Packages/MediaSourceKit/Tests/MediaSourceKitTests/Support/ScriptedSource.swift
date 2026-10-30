import Foundation
import MediaSourceKit

/// A source whose shelf contributions the test publishes by hand.
actor ScriptedSource: MediaSource {
    nonisolated let id: SourceID
    nonisolated let kind: SourceKind
    private let sourceCapabilities: SourceCapabilities
    private var current: [ShelfContribution]?
    private var continuations: [AsyncStream<[ShelfContribution]>.Continuation] = []
    private var items: [MediaItemID: MediaItem] = [:]
    private(set) var lookups: [MediaItemID] = []
    private(set) var subscriptions = 0

    /// - Parameter initial: published as soon as the composer subscribes; nil keeps the source silent.
    init(id: SourceID, kind: SourceKind = .plex, capabilities: SourceCapabilities,
         initial: [ShelfContribution]? = nil, lookupItems: [MediaItem] = []) {
        self.id = id
        self.kind = kind
        sourceCapabilities = capabilities
        current = initial
        for item in lookupItems { items[item.id] = item }
    }

    func publish(_ batch: [ShelfContribution]) {
        current = batch
        for continuation in continuations { continuation.yield(batch) }
    }

    func capabilities() -> SourceCapabilities { sourceCapabilities }

    func status() -> SourceStatus { .ready }

    func children(of parent: MediaItemID?, page: PageRequest) -> Page<MediaItem> {
        Page(slicing: Array(items.values).sorted { $0.cardID < $1.cardID }, with: page)
    }

    func item(_ id: MediaItemID) throws -> MediaItem {
        lookups.append(id)
        guard let item = items[id] else { throw MediaSourceError.notFound(id) }
        return item
    }

    func playback(for id: MediaItemID, request: PlaybackRequest) throws -> PlaybackDescriptor {
        throw MediaSourceError.notPlayable(id)
    }

    func shelfContributions() async -> AsyncStream<[ShelfContribution]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [ShelfContribution].self)
        subscriptions += 1
        continuations.append(continuation)
        if let current { continuation.yield(current) }
        return stream
    }
}

/// A source that never feeds Home: it keeps the protocol's default empty stream.
actor ShelflessSource: MediaSource {
    nonisolated let id: SourceID
    nonisolated let kind = SourceKind.folder

    init(id: SourceID) {
        self.id = id
    }

    func capabilities() -> SourceCapabilities { [.browse] }
    func status() -> SourceStatus { .ready }
    func children(of parent: MediaItemID?, page: PageRequest) -> Page<MediaItem> { Page(items: []) }
    func item(_ id: MediaItemID) throws -> MediaItem { throw MediaSourceError.notFound(id) }
    func playback(for id: MediaItemID, request: PlaybackRequest) throws -> PlaybackDescriptor {
        throw MediaSourceError.notPlayable(id)
    }
}

enum Sample {
    static let plex = SourceID(raw: "plex:0f0e0d0c")
    static let antenna = SourceID.hdhomerunLive(lineupSource: "Antenna")

    static func channel(_ number: String, favorite: Bool = false, source: SourceID = antenna) -> MediaItem {
        MediaItem(id: MediaItemID(source: source, key: "ch:\(number)"),
                  kind: .channel(number: number, callSign: "K\(number)", isHD: true, isFavorite: favorite),
                  title: "K\(number)", subtitle: number)
    }

    static func movie(_ key: String, source: SourceID = plex, artwork: Artwork = Artwork()) -> MediaItem {
        MediaItem(id: MediaItemID(source: source, key: "plex:\(key)"), kind: .movie(year: 1999),
                  title: "Movie \(key)", artwork: artwork)
    }

    static func recording(_ key: String, inProgress: Bool, source: SourceID = plex) -> MediaItem {
        MediaItem(id: MediaItemID(source: source, key: "plex:\(key)"),
                  kind: .recording(airedAt: nil, recordedAt: nil, inProgress: inProgress, channel: "4.1"),
                  title: "Recording \(key)")
    }

    static func liveContributions(_ channels: [MediaItem]) -> [ShelfContribution] {
        [
            ShelfContribution(shelf: .favorites, items: channels.filter(\.isDeviceFavorite), freshness: .now),
            ShelfContribution(shelf: .liveChannels, items: channels, freshness: .now)
        ]
    }
}

extension MediaItem {
    /// The item's key within its source, for compact expectations.
    var key: String { id.key }
}
