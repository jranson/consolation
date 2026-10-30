import Foundation

/// A Bullpen server as a `MediaSource`: its live channels through Bullpen's proxy, and its OPDS library
/// (recordings, series, movies, TV).
///
/// - Top level: "Live TV" (`live:`) when the catalog offers channels, then the library root's navigation feeds
///   (`feed:<path>`). Feeds list their navigation as folders and their publications (`pub:<identifier>`) as items,
///   following `next` pages as far as a page request reaches.
/// - Live channels are `ch:<identifier>` (`ch:bullpen:ch/antenna-9-1`) and play the proxy's HLS stream. Recordings
///   play their acquisition link; one still being written grows and starts at its beginning.
/// - Read-only. It connects only to the server's own origin: artwork on other hosts is left out, so cards draw
///   their own faces. Sign-in (an `oidc-issuer` in the catalog) isn't built yet; such a server reports
///   `authRequired`.
/// - No network until a method that needs the server is called (`id`, `kind`, `status()` never connect).
public actor BullpenSource: LibraryServerSource {
    public nonisolated let id: SourceID
    public nonisolated let kind = SourceKind.bullpen
    public nonisolated let name: String

    static let liveKey = "live:"
    static let channelPrefix = "ch:"
    /// How long a fetched feed or channel list is reused before it's read again.
    static let maxAge: Duration = .seconds(60)
    /// The most pages one request follows.
    static let maxPages = 20

    let client: BullpenClient
    private var catalog: APICatalog?
    private var currentStatus = SourceStatus.ready
    private var feeds: [String: CachedFeed] = [:]
    private var channelCache: (channels: [BullpenChannel], readAt: ContinuousClock.Instant)?
    /// Every publication seen, by key, with the feed URL its links resolve against.
    private var publications: [String: (publication: OPDSPublication, base: URL)] = [:]
    var observers = ContributionObservers()
    var lastContributions: [ShelfContribution]?
    var shelfTask: Task<Void, Never>?

    /// One feed's pages read so far, in order.
    struct CachedFeed {
        var title: String
        var folders: [MediaItem]
        var items: [MediaItem]
        var next: URL?
        var readAt: ContinuousClock.Instant
    }

    public init(id: SourceID, name: String, client: BullpenClient) {
        self.id = id
        self.name = name
        self.client = client
    }

    /// What a Bullpen server offers until its catalog is read (Home picks its placeholders from this before the
    /// server answers); afterwards, what the catalog lists. Not `liveTV` yet: its channels play from the Library
    /// pane but don't feed the Favorites and Live TV Channels shelves or the Live TV pane.
    static let expectedCapabilities: SourceCapabilities = [
        .browse, .recordings, .inProgressRecordings, .serverArtwork, .directPlay
    ]

    public func capabilities() -> SourceCapabilities {
        guard let catalog else { return Self.expectedCapabilities }
        var capabilities: SourceCapabilities = [.directPlay]
        if catalog.has(BullpenVocabulary.library) { capabilities.formUnion([.browse, .recordings, .serverArtwork]) }
        if catalog.has(BullpenVocabulary.recordings) { capabilities.insert(.inProgressRecordings) }
        if catalog.has(BullpenVocabulary.oidcIssuer) { capabilities.insert(.requiresAuth) }
        return capabilities
    }

    public func status() -> SourceStatus {
        currentStatus
    }

    // MARK: - Browsing

    public func children(of parent: MediaItemID?, page: PageRequest) async throws -> Page<MediaItem> {
        guard let parent else { return Page(slicing: try await topLevel(), with: page) }
        guard parent.source == id else { throw MediaSourceError.wrongSource(parent) }
        if parent.key == Self.liveKey {
            return Page(slicing: try await channels().map(channelItem), with: page)
        }
        // A video or a channel has no children.
        guard parent.key.hasPrefix(OPDSItems.feedPrefix) else { return Page(items: [], total: 0) }
        let feedURL = try client.resolve(String(parent.key.dropFirst(OPDSItems.feedPrefix.count).drop { $0 == "/" }))
        let feed = try await feed(at: feedURL, reaching: page.offset.addingReportingOverflow(page.limit).partialValue)
        return Page(slicing: feed.folders + feed.items, with: page)
    }

    public func item(_ itemID: MediaItemID) async throws -> MediaItem {
        guard itemID.source == id else { throw MediaSourceError.wrongSource(itemID) }
        if let cached = publications[itemID.key] {
            if let item = publicationItem(cached.publication, base: cached.base) { return item }
        }
        if itemID.key.hasPrefix(Self.channelPrefix),
           let channel = try await channels().first(where: { channelKey($0) == itemID.key }) {
            return channelItem(channel)
        }
        throw MediaSourceError.notFound(itemID)
    }

    public func playback(for itemID: MediaItemID, request: PlaybackRequest) async throws -> PlaybackDescriptor {
        guard itemID.source == id else { throw MediaSourceError.wrongSource(itemID) }
        if itemID.key.hasPrefix(Self.channelPrefix) {
            guard let channel = try await channels().first(where: { channelKey($0) == itemID.key }),
                  let link = channel.streamLink(), let url = try? client.resolve(link.href) else {
                throw MediaSourceError.notFound(itemID)
            }
            return Self.liveDescriptor(url: url, type: link.type)
        }
        guard let (publication, base) = try await publication(for: itemID) else {
            throw MediaSourceError.notFound(itemID)
        }
        guard let choice = OPDSPlayback.choice(for: publication, base: base) else {
            throw MediaSourceError.notPlayable(itemID)
        }
        var descriptor = OPDSPlayback.descriptor(for: choice, metadata: publication.metadata)
        if let start = request.start { descriptor.start = start }
        return descriptor
    }

    static func liveDescriptor(url: URL, type: String?) -> PlaybackDescriptor {
        let container = OPDSPlayback.container(for: OPDSLink(href: url.absoluteString, type: type).mediaType)
        let transport: PlaybackDescriptor.Transport = switch container {
        case .hls: .hls(url, headers: [:])
        case .dash: .dash(url)
        default: .http(url, headers: [:])
        }
        return PlaybackDescriptor(transport: transport, container: container ?? .unknown, isLive: true,
                                  start: .liveEdge)
    }

    // MARK: - Reading the server

    /// The catalog, read once per source; a failure is remembered in the status and thrown.
    func currentCatalog() async throws -> APICatalog {
        if let catalog { return catalog }
        do {
            let read = try await client.catalog()
            catalog = read
            currentStatus = read.has(BullpenVocabulary.oidcIssuer) ? .authRequired : .ready
            return read
        } catch {
            currentStatus = Self.status(for: error)
            throw error
        }
    }

    private func topLevel() async throws -> [MediaItem] {
        let catalog = try await currentCatalog()
        try requireOpen(catalog)
        var items: [MediaItem] = []
        if catalog.has(BullpenVocabulary.channels) {
            items.append(MediaItem(id: MediaItemID(source: id, key: Self.liveKey), kind: .folder, title: "Live TV"))
        }
        if let root = catalog.url(BullpenVocabulary.library) {
            items += try await feed(at: root, reaching: 0).folders
        }
        return items
    }

    func channels() async throws -> [BullpenChannel] {
        if let channelCache, ContinuousClock.now - channelCache.readAt < Self.maxAge { return channelCache.channels }
        let catalog = try await currentCatalog()
        try requireOpen(catalog)
        guard let url = catalog.url(BullpenVocabulary.channels) else { return [] }
        let channels = try await tracking { try await client.channels(at: url) }.filter { !$0.isHidden }
        channelCache = (channels, .now)
        return channels
    }

    /// The feed at `url` with at least `count` entries read (or all of them), reusing pages read recently.
    func feed(at url: URL, reaching count: Int) async throws -> CachedFeed {
        let key = OPDSItems.key(forFeed: url)
        var cached: CachedFeed
        if let existing = feeds[key], ContinuousClock.now - existing.readAt < Self.maxAge {
            cached = existing
        } else {
            let first = try await tracking { try await client.feed(at: url) }
            cached = CachedFeed(title: first.title, folders: [], items: [], next: nil, readAt: .now)
            absorb(first, from: url, into: &cached)
        }
        var pages = 1
        while cached.folders.count + cached.items.count < count, let next = cached.next, pages < Self.maxPages {
            absorb(try await tracking { try await client.feed(at: next) }, from: next, into: &cached)
            pages += 1
        }
        feeds[key] = cached
        return cached
    }

    private func absorb(_ feed: OPDSFeed, from url: URL, into cached: inout CachedFeed) {
        cached.folders += feed.navigation.compactMap { OPDSItems.folder(for: $0, source: id, base: url) }
        cached.items += remember(feed.publications, base: url)
        cached.next = feed.next?.url(relativeTo: url)
    }

    /// Items for publications, remembered so they can be played and looked up later.
    func remember(_ list: [OPDSPublication], base: URL) -> [MediaItem] {
        list.compactMap { publication in
            guard let item = publicationItem(publication, base: base) else { return nil }
            publications[item.id.key] = (publication, base)
            return item
        }
    }

    private func publication(for itemID: MediaItemID) async throws -> (OPDSPublication, URL)? {
        if let cached = publications[itemID.key] { return cached }
        // Not seen since launch (a card from Home's snapshot): the shelves' feeds are read again to find it.
        await refreshShelves()
        return publications[itemID.key].map { ($0.publication, $0.base) }
    }

    private func publicationItem(_ publication: OPDSPublication, base: URL) -> MediaItem? {
        let origin = client.baseURL
        return OPDSItems.item(for: publication, source: id, base: base) { Self.isSameOrigin($0, origin) }
    }

    func channelKey(_ channel: BullpenChannel) -> String {
        Self.channelPrefix + channel.identifier
    }

    private func channelItem(_ channel: BullpenChannel) -> MediaItem {
        let callSign = channel.callSign ?? channel.name ?? channel.number
        return MediaItem(id: MediaItemID(source: id, key: channelKey(channel)),
                         kind: .channel(number: channel.number, callSign: callSign, isHD: false, isFavorite: false),
                         title: channel.name ?? callSign, subtitle: channel.number)
    }

    private func requireOpen(_ catalog: APICatalog) throws {
        if catalog.has(BullpenVocabulary.oidcIssuer) { throw RemoteDocumentError.status(401, nil) }
    }

    /// Runs a request, keeping the status current.
    private func tracking<T>(_ request: () async throws -> T) async throws -> T {
        do {
            let value = try await request()
            if currentStatus != .authRequired { currentStatus = .ready }
            return value
        } catch {
            currentStatus = Self.status(for: error)
            throw error
        }
    }

    static func status(for error: any Error) -> SourceStatus {
        switch error as? RemoteDocumentError {
        case .status(401, _), .status(403, _): .authRequired
        case .status(let code, let problem): .unreachable(problem?.message ?? "The server answered HTTP \(code).")
        case .unreachable(let message): .unreachable(message)
        case .tooLarge, .malformed: .degraded("The server sent something unexpected.")
        case nil: .unreachable(error.localizedDescription)
        }
    }

    static func isSameOrigin(_ url: URL, _ origin: URL) -> Bool {
        url.scheme?.lowercased() == origin.scheme?.lowercased()
            && url.host()?.lowercased() == origin.host()?.lowercased() && url.port == origin.port
    }
}
