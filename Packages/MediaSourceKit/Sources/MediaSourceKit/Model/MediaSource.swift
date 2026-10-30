import Foundation

/// A configured source: an HDHomeRun lineup, the Quick Play history, a Plex server, a folder.
///
/// Every source is an `actor` (the protocol requires a reference type, so Home can tell a rebuilt source from the
/// one it replaces). Network calls, parsing and scanning run on that actor or in `@concurrent` functions, never on
/// the main actor. A source makes no network connection until one of its methods is called (`id`, `kind`,
/// `status()` and, for sources that know them up front, `capabilities()` never touch the network).
public nonisolated protocol MediaSource: AnyObject, Sendable {
    var id: SourceID { get }
    var kind: SourceKind { get }
    func capabilities() async -> SourceCapabilities
    /// What the source last saw. Never connects; Home asks for it with every shelf batch.
    func status() async -> SourceStatus
    /// The children of `parent`, or the top level when `parent` is nil.
    func children(of parent: MediaItemID?, page: PageRequest) async throws -> Page<MediaItem>
    func item(_ id: MediaItemID) async throws -> MediaItem
    /// How to play an item. A live tuner descriptor already holds the tuner: release its lease when done.
    func playback(for id: MediaItemID, request: PlaybackRequest) async throws -> PlaybackDescriptor
    /// The Home shelves this source feeds. Each element replaces everything the source contributed before.
    /// The default is an empty stream that finishes at once.
    ///
    /// An actor that implements it must declare it `async`: a synchronous actor method loses to this default when
    /// called directly on the actor's type (`await source.shelfContributions()`), and the caller gets an empty stream.
    func shelfContributions() async -> AsyncStream<[ShelfContribution]>
}

nonisolated extension MediaSource {
    public func shelfContributions() async -> AsyncStream<[ShelfContribution]> {
        AsyncStream { $0.finish() }
    }
}

/// A source's health, for the sidebar, Settings and the "no source" banners.
public nonisolated enum SourceStatus: Hashable, Sendable {
    case unconfigured
    case connecting
    case ready
    case authRequired
    case unreachable(String)
    /// Local Network access is off: the UI links to Settings instead of showing a generic error.
    case localNetworkDenied
    case degraded(String)
}

/// Model-level failures shared by every source. Device and server errors keep their own types
/// (`HDHomeRunClientError` for tuners).
public nonisolated enum MediaSourceError: Error, Hashable, Sendable {
    /// The item is not (or no longer) in the source.
    case notFound(MediaItemID)
    /// The item belongs to another source.
    case wrongSource(MediaItemID)
    /// The item is a container (folder, series), not something to play.
    case notPlayable(MediaItemID)
    /// The source has nothing configured to read from.
    case unconfigured
}

/// A window into a source's list.
public nonisolated struct PageRequest: Hashable, Sendable {
    public var offset: Int
    public var limit: Int

    public init(offset: Int = 0, limit: Int) {
        self.offset = max(offset, 0)
        self.limit = max(limit, 0)
    }

    /// Everything at once.
    public static let all = PageRequest(offset: 0, limit: .max)
}

/// One page of a source's list.
public nonisolated struct Page<Item: Sendable>: Sendable {
    public var items: [Item]
    /// The total count, when the source knows it.
    public var total: Int?
    /// The request for the next page, or nil on the last one.
    public var next: PageRequest?

    public init(items: [Item], total: Int? = nil, next: PageRequest? = nil) {
        self.items = items
        self.total = total
        self.next = next
    }

    /// The window of `all` that `request` asks for. A page that can't advance (a limit of 0) has no next page,
    /// so a pager never loops on it.
    public init(slicing all: [Item], with request: PageRequest) {
        let start = min(request.offset, all.count)
        let available = all.count - start
        let count = min(request.limit, available)
        let end = start + count
        items = Array(all[start..<end])
        total = all.count
        next = count > 0 && end < all.count ? PageRequest(offset: end, limit: request.limit) : nil
    }
}

nonisolated extension Page: Equatable where Item: Equatable {}
nonisolated extension Page: Hashable where Item: Hashable {}
