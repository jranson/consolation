import Foundation

/// What Home renders from at launch, before any source answers: each source's last contributions, kept in Caches.
/// It holds MediaItems only, never a secret (`sanitizedForSnapshot()` drops artwork URLs that could carry one).
public nonisolated struct HomeSnapshot: Hashable, Codable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var sources: [SourceSnapshot]

    public init(sources: [SourceSnapshot], version: Int = HomeSnapshot.currentVersion) {
        self.version = version
        self.sources = sources
    }
}

/// One source's part of the snapshot.
public nonisolated struct SourceSnapshot: Hashable, Codable, Sendable {
    public var source: SourceID
    public var capabilities: SourceCapabilities?
    public var contributions: [ShelfContribution]
    /// Items fetched one by one for local favorites and resume points that no shelf contribution carried.
    public var resolvedItems: [MediaItem]

    public init(source: SourceID, capabilities: SourceCapabilities?, contributions: [ShelfContribution],
                resolvedItems: [MediaItem] = []) {
        self.source = source
        self.capabilities = capabilities
        self.contributions = contributions
        self.resolvedItems = resolvedItems
    }
}

/// Where the composer keeps its snapshot. The app passes a file in Caches (`FileHomeSnapshotStore`).
public nonisolated protocol HomeSnapshotStore: Sendable {
    func loadSnapshot() async -> HomeSnapshot?
    func saveSnapshot(_ snapshot: HomeSnapshot) async
}

/// For tests and previews.
public actor InMemoryHomeSnapshotStore: HomeSnapshotStore {
    public private(set) var snapshot: HomeSnapshot?
    public private(set) var saveCount = 0

    public init(_ snapshot: HomeSnapshot? = nil) {
        self.snapshot = snapshot
    }

    public func loadSnapshot() -> HomeSnapshot? {
        snapshot
    }

    public func saveSnapshot(_ snapshot: HomeSnapshot) {
        self.snapshot = snapshot
        saveCount += 1
    }
}

/// A JSON file, written atomically. The system may purge Caches at any time, so a missing or unreadable file is
/// simply no snapshot.
public actor FileHomeSnapshotStore: HomeSnapshotStore {
    public nonisolated let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func loadSnapshot() -> HomeSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(HomeSnapshot.self, from: data),
              snapshot.version == HomeSnapshot.currentVersion else { return nil }
        return snapshot
    }

    public func saveSnapshot(_ snapshot: HomeSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic])
    }
}

nonisolated extension MediaItem {
    /// The item as it may be cached: remote artwork whose URL has a user, password, query or fragment is dropped
    /// (the card shows its generated face until the source refreshes), so no token reaches the disk.
    public func sanitizedForSnapshot() -> MediaItem {
        var copy = self
        copy.artwork = artwork.sanitizedForSnapshot()
        return copy
    }
}

nonisolated extension Artwork {
    func sanitizedForSnapshot() -> Artwork {
        Artwork(poster: poster?.sanitizedForSnapshot(), thumb: thumb?.sanitizedForSnapshot(),
                backdrop: backdrop?.sanitizedForSnapshot(), logo: logo?.sanitizedForSnapshot())
    }
}

nonisolated extension ArtworkRef {
    func sanitizedForSnapshot() -> ArtworkRef? {
        guard case .remote(let url, _) = self else { return self }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return nil }
        return self
    }
}

nonisolated extension ShelfContribution {
    func sanitizedForSnapshot() -> ShelfContribution {
        var copy = self
        copy.items = items.map { $0.sanitizedForSnapshot() }
        return copy
    }
}

nonisolated extension SourceSnapshot {
    /// What may be cached for Home: contributions to shelves that are shown only (Quick Play History is off by
    /// default, and its hosts and file names stay out of Caches with it), items looked up for local favorites and
    /// resume points only while a shelf shows them, and artwork URLs that could carry a token removed.
    func cacheable(showing shown: Set<HomeShelfKind>) -> SourceSnapshot {
        let showsLocalItems = shown.contains(.favorites) || shown.contains(.continueWatching)
        return SourceSnapshot(
            source: source, capabilities: capabilities,
            contributions: contributions.filter { shown.contains($0.shelf) }.map { $0.sanitizedForSnapshot() },
            resolvedItems: showsLocalItems ? resolvedItems.map { $0.sanitizedForSnapshot() } : [])
    }
}
