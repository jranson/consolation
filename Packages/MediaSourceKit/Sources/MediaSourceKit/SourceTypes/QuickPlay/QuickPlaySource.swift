import CryptoKit
import Foundation
import PlaybackKit

/// One URL the user played from Quick Play.
public nonisolated struct QuickPlayHistoryEntry: Hashable, Sendable {
    public var url: URL
    public var lastPlayed: Date

    public init(url: URL, lastPlayed: Date) {
        self.url = url
        self.lastPlayed = lastPlayed
    }
}

/// Quick Play history as a `MediaSource`. The app owns the history (on this device only, never synced) and hands it in;
/// this source turns it into items and descriptors.
///
/// URLs can carry tokens, so an item never holds its URL: its key is `url:<SHA-256 hex of the URL>`, its title the
/// last path component (the host instead when that looks like a token; see `QuickPlayTitle`) and its subtitle the
/// host. The URL stays in this actor's memory for `playback(for:)`.
public actor QuickPlaySource: MediaSource {
    public nonisolated let id: SourceID
    public nonisolated let kind = SourceKind.quickPlay

    private var entries: [QuickPlayHistoryEntry] = []
    private var urlsByKey: [String: URL] = [:]
    private var observers = ContributionObservers()

    public init(id: SourceID = .quickPlay, history: [QuickPlayHistoryEntry] = []) {
        self.id = id
        (entries, urlsByKey) = Self.index(history)
    }

    /// `url:<SHA-256 hex of the absolute URL>`. The URL itself never appears in an ID.
    public nonisolated static func itemKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return MediaItemID.urlKeyPrefix + digest.map { String(format: "%02x", $0) }.joined()
    }

    public nonisolated func itemID(for url: URL) -> MediaItemID {
        MediaItemID(source: id, key: Self.itemKey(for: url))
    }

    /// Replaces the history (newest first after sorting) and publishes the Quick Play History shelf.
    public func setHistory(_ history: [QuickPlayHistoryEntry]) {
        (entries, urlsByKey) = Self.index(history)
        observers.yield(contributions())
    }

    public func capabilities() -> SourceCapabilities {
        [.browse, .directPlay]
    }

    public func status() -> SourceStatus {
        .ready
    }

    public func children(of parent: MediaItemID?, page: PageRequest) throws -> Page<MediaItem> {
        guard let parent else { return Page(slicing: items(), with: page) }
        _ = try url(for: parent)
        return Page(items: [], total: 0)
    }

    public func item(_ itemID: MediaItemID) throws -> MediaItem {
        let url = try url(for: itemID)
        guard let entry = entries.first(where: { $0.url == url }) else { throw MediaSourceError.notFound(itemID) }
        return item(for: entry)
    }

    /// `.hls`, `.dash` or `.http` by URL kind, without touching the network. Raw MPEG-TS URLs are live streams,
    /// as Quick Play treats them today; everything else starts at the beginning unless the request says otherwise.
    public func playback(for itemID: MediaItemID, request: PlaybackRequest) throws -> PlaybackDescriptor {
        let url = try url(for: itemID)
        if url.isFileURL {
            return PlaybackDescriptor(transport: .file(url), start: request.start ?? .beginning)
        }
        switch URLKindDetector.detect(url) {
        case .hls:
            return PlaybackDescriptor(transport: .hls(url, headers: [:]), container: .hls,
                                      start: request.start ?? .beginning)
        case .dash:
            return PlaybackDescriptor(transport: .dash(url), container: .dash, start: request.start ?? .beginning)
        case .transportStream:
            return PlaybackDescriptor(transport: .http(url, headers: [:]), container: .mpegTS, isLive: true,
                                      start: .liveEdge)
        case .progressive:
            let container: ContainerHint = url.pathExtension.lowercased() == "mov" ? .mov : .mp4
            return PlaybackDescriptor(transport: .http(url, headers: [:]), container: container,
                                      start: request.start ?? .beginning)
        case .unknown:
            return PlaybackDescriptor(transport: .http(url, headers: [:]), container: .unknown,
                                      start: request.start ?? .beginning)
        }
    }

    /// The Quick Play History shelf now, then whenever the history changes.
    public func shelfContributions() async -> AsyncStream<[ShelfContribution]> {
        let (stream, continuation) = ContributionObservers.makeStream()
        let observerID = observers.add(continuation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(observerID) }
        }
        continuation.yield(contributions())
        return stream
    }

    // MARK: - Internals

    private func removeObserver(_ observerID: UInt64) {
        observers.remove(observerID)
    }

    private func url(for itemID: MediaItemID) throws -> URL {
        guard itemID.source == id else { throw MediaSourceError.wrongSource(itemID) }
        guard let url = urlsByKey[itemID.key] else { throw MediaSourceError.notFound(itemID) }
        return url
    }

    private func items() -> [MediaItem] {
        entries.map(item(for:))
    }

    private func item(for entry: QuickPlayHistoryEntry) -> MediaItem {
        let id = itemID(for: entry.url)
        let (title, isHost) = QuickPlayTitle.title(for: entry.url)
        return MediaItem(id: id, kind: .clip, title: title, subtitle: isHost ? nil : entry.url.host(),
                         artwork: Artwork(thumb: .stylized(seed: id.cardID)), addedAt: entry.lastPlayed)
    }

    private func contributions() -> [ShelfContribution] {
        [ShelfContribution(shelf: .quickPlayHistory, items: items(),
                           freshness: entries.first?.lastPlayed ?? .distantPast)]
    }

    /// Newest first, one entry per URL (its latest play).
    private static func index(_ history: [QuickPlayHistoryEntry]) -> ([QuickPlayHistoryEntry], [String: URL]) {
        var seen: Set<URL> = []
        let newestFirst = history.sorted { $0.lastPlayed > $1.lastPlayed }.filter { seen.insert($0.url).inserted }
        var urls: [String: URL] = [:]
        for entry in newestFirst { urls[itemKey(for: entry.url)] = entry.url }
        return (newestFirst, urls)
    }
}
