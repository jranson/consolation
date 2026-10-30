import Foundation

/// A Plex Media Server as a `MediaSource`, read-only and LAN-only, playing files directly (no Plex transcoder).
///
/// - Top level: the server's video sections (`section:<key>`). A section lists its shows or movies (paged on the
///   server), a show its seasons, a season its episodes; every item is `plex:<ratingKey>`.
/// - Recordings (media with origin `dvr`) are `.recording` items; Recent Recordings comes from the sections the
///   DVR records into (its subscriptions' target sections).
/// - Playback is the item's first part (`/library/parts/…`) over HTTP with the token header: MPEG-TS recordings in
///   our TS engine (seeking with range requests), MP4 in AVPlayer. A recording still being written is reported as
///   growing, which the engines can't follow over HTTP yet.
/// - Artwork is on the server and needs the token, so it names the header; the app loads it only once it has an
///   image loader that adds it.
/// - No network until a method that needs the server is called.
public actor PlexSource: LibraryServerSource {
    public nonisolated let id: SourceID
    public nonisolated let kind = SourceKind.plex
    public nonisolated let name: String

    static let sectionPrefix = "section:"
    static let itemPrefix = "plex:"
    /// Section types with video.
    static let videoSections: Set<String> = ["show", "movie"]
    static let recentLimit = 30
    /// The most a section lists at once when asked for everything.
    static let maxPage = 500

    let client: PlexClient
    private var currentStatus = SourceStatus.ready
    /// Every item seen, by rating key, so items and playback don't refetch what a listing just read.
    private var known: [String: PlexClient.Metadata] = [:]
    var observers = ContributionObservers()
    var lastContributions: [ShelfContribution]?
    var shelfTask: Task<Void, Never>?

    public init(id: SourceID, name: String, client: PlexClient) {
        self.id = id
        self.name = name
        self.client = client
    }

    public func capabilities() -> SourceCapabilities {
        var capabilities: SourceCapabilities = [.browse, .recordings, .serverArtwork, .directPlay]
        if !client.mediaHeaders.isEmpty { capabilities.insert(.requiresAuth) }
        return capabilities
    }

    public func status() -> SourceStatus {
        currentStatus
    }

    // MARK: - Browsing

    public func children(of parent: MediaItemID?, page: PageRequest) async throws -> Page<MediaItem> {
        guard let parent else {
            let sections = try await tracking { try await client.sections() }
            let folders = sections.filter { Self.videoSections.contains($0.type) }.map { section in
                MediaItem(id: MediaItemID(source: id, key: Self.sectionPrefix + section.key), kind: .folder,
                          title: section.title)
            }
            return Page(slicing: folders, with: page)
        }
        guard parent.source == id else { throw MediaSourceError.wrongSource(parent) }
        if parent.key.hasPrefix(Self.sectionPrefix) {
            let section = String(parent.key.dropFirst(Self.sectionPrefix.count))
            let size = min(page.limit, Self.maxPage)
            let container = try await tracking {
                try await client.items(inSection: section, start: page.offset, size: size)
            }
            let items = remember(container.metadata)
            let total = container.totalSize
            let end = page.offset + items.count
            let more = !items.isEmpty && (total.map { end < $0 } ?? (items.count == size))
            return Page(items: items, total: total, next: more ? PageRequest(offset: end, limit: page.limit) : nil)
        }
        guard let ratingKey = Self.ratingKey(parent) else { return Page(items: [], total: 0) }
        let children = try await tracking { try await client.children(of: ratingKey) }
        return Page(slicing: remember(children), with: page)
    }

    public func item(_ itemID: MediaItemID) async throws -> MediaItem {
        guard itemID.source == id else { throw MediaSourceError.wrongSource(itemID) }
        guard let ratingKey = Self.ratingKey(itemID) else { throw MediaSourceError.notFound(itemID) }
        if let metadata = known[ratingKey] { return mediaItem(metadata) }
        guard let metadata = try await tracking({ try await client.metadata(ratingKey) }) else {
            throw MediaSourceError.notFound(itemID)
        }
        known[ratingKey] = metadata
        return mediaItem(metadata)
    }

    /// The first part of the item's first media, read fresh (a part changes when Plex rewrites the file).
    public func playback(for itemID: MediaItemID, request: PlaybackRequest) async throws -> PlaybackDescriptor {
        guard itemID.source == id else { throw MediaSourceError.wrongSource(itemID) }
        guard let ratingKey = Self.ratingKey(itemID),
              let metadata = try await tracking({ try await client.metadata(ratingKey) }) else {
            throw MediaSourceError.notFound(itemID)
        }
        known[ratingKey] = metadata
        guard let media = metadata.media?.first, let part = media.parts?.first, let path = part.key,
              let url = client.url(path: path) else { throw MediaSourceError.notPlayable(itemID) }
        let growing = media.mediaGrabStatus == "inprogress"
        return PlaybackDescriptor(transport: .http(url, headers: client.mediaHeaders),
                                  container: Self.container(part.container ?? media.container),
                                  isGrowing: growing, start: request.start ?? .beginning)
    }

    // MARK: - Items

    func remember(_ list: [PlexClient.Metadata]) -> [MediaItem] {
        list.map { metadata in
            known[metadata.ratingKey] = metadata
            return mediaItem(metadata)
        }
    }

    func mediaItem(_ metadata: PlexClient.Metadata) -> MediaItem {
        let media = metadata.media?.first
        let title = metadata.title ?? ""
        var item = MediaItem(
            id: MediaItemID(source: id, key: Self.itemPrefix + metadata.ratingKey), kind: Self.kind(of: metadata),
            title: title, synopsis: metadata.summary, artwork: artwork(metadata),
            duration: metadata.duration.map { Duration.milliseconds($0) },
            addedAt: metadata.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            technical: media.map { CodecHints(container: Self.container($0.container)) })
        switch item.kind {
        case .recording, .episode:
            // A recording's card names the show; the episode's own title (often the show's again) is the detail.
            if let show = metadata.grandparentTitle, !show.isEmpty {
                item.title = show
                item.subtitle = title == show ? nil : title
            }
        case .series:
            item.subtitle = metadata.year.map(String.init)
        default:
            break
        }
        return item
    }

    static func kind(of metadata: PlexClient.Metadata) -> MediaItem.Kind {
        let media = metadata.media?.first
        let aired = metadata.originallyAvailableAt.flatMap(airDate)
        let added = metadata.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        switch metadata.type {
        case "show": return .series
        case "season": return .season(metadata.index ?? 0)
        case "movie": return .movie(year: metadata.year)
        case "episode" where media?.origin == "dvr":
            return .recording(airedAt: aired, recordedAt: added,
                              inProgress: media?.mediaGrabStatus == "inprogress",
                              channel: metadata.channels.first ?? media?.channelTitle)
        case "episode":
            return .episode(series: metadata.grandparentTitle ?? "", season: metadata.parentIndex,
                            episode: metadata.index, airDate: aired)
        default:
            return media == nil ? .folder : .clip
        }
    }

    /// `2026-10-25`, or `2026-11-01 05:00:00` (an airing, in UTC).
    static func airDate(_ text: String) -> Date? {
        let iso = text.count > 10 ? text.replacingOccurrences(of: " ", with: "T") + "Z" : text
        return OPDSDates.parse(iso)
    }

    static func container(_ name: String?) -> ContainerHint {
        switch name?.lowercased() {
        case "mpegts", "ts": .mpegTS
        case "mp4", "m4v": .mp4
        case "mov": .mov
        case "mkv": .mkv
        default: .unknown
        }
    }

    private func artwork(_ metadata: PlexClient.Metadata) -> Artwork {
        let headerKeys: Set<String> = client.mediaHeaders.isEmpty ? [] : [PlexClient.tokenHeader]
        func ref(_ path: String?) -> ArtworkRef? {
            path.flatMap { client.url(path: $0) }.map { .remote($0, headerKeys: headerKeys) }
        }
        switch metadata.type {
        case "show", "season", "movie": return Artwork(poster: ref(metadata.thumb), backdrop: ref(metadata.art))
        default: return Artwork(thumb: ref(metadata.thumb), backdrop: ref(metadata.art))
        }
    }

    static func ratingKey(_ itemID: MediaItemID) -> String? {
        guard itemID.key.hasPrefix(itemPrefix) else { return nil }
        let key = String(itemID.key.dropFirst(itemPrefix.count))
        return key.isEmpty ? nil : key
    }

    // MARK: - Status

    /// Runs a request, keeping the status current.
    func tracking<T>(_ request: () async throws -> T) async throws -> T {
        do {
            let value = try await request()
            currentStatus = .ready
            return value
        } catch {
            currentStatus = BullpenSource.status(for: error)
            throw error
        }
    }
}

extension SourceID {
    /// A Plex server, by its `machineIdentifier`, so a changed address is the same source.
    public static func plex(machineIdentifier: String) -> SourceID {
        SourceID(raw: "plex:" + machineIdentifier)
    }
}
