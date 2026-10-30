import Foundation

/// One row of Settings › Home: a shelf and whether it shows.
public nonisolated struct HomeShelfSetting: Hashable, Codable, Sendable {
    public var kind: HomeShelfKind
    public var isEnabled: Bool

    public init(kind: HomeShelfKind, isEnabled: Bool = true) {
        self.kind = kind
        self.isEnabled = isEnabled
    }
}

/// The shelf order and per-shelf switches, injected by the app (Settings › Home). Only listed shelves appear,
/// so a library section shows on Home once the user pins it here.
public nonisolated struct HomeShelfConfiguration: Hashable, Codable, Sendable {
    public var shelves: [HomeShelfSetting]

    public init(shelves: [HomeShelfSetting]) {
        self.shelves = shelves
    }

    /// Favorites, Live TV Channels, Recording Now, Recent Recordings and Continue Watching on; Quick Play History
    /// off, because stream URLs often carry tokens and Home is the screen others see most.
    public static let `default` = HomeShelfConfiguration(shelves: HomeShelfKind.builtIn.map {
        HomeShelfSetting(kind: $0, isEnabled: $0 != .quickPlayHistory)
    })
}

/// What only this device knows, merged into Home: local favorites (any item) and local resume positions.
public nonisolated struct LocalHomeState: Hashable, Sendable {
    /// In the user's order. A local favorite that is also a device favorite shows once.
    public var favorites: [MediaItemID]
    public var resumePoints: [ResumePoint]

    public init(favorites: [MediaItemID] = [], resumePoints: [ResumePoint] = []) {
        self.favorites = favorites
        self.resumePoints = resumePoints
    }
}

/// A local resume position, the source of Continue Watching.
public nonisolated struct ResumePoint: Hashable, Codable, Sendable {
    public var item: MediaItemID
    public var progress: PlaybackProgress

    public init(item: MediaItemID, progress: PlaybackProgress) {
        self.item = item
        self.progress = progress
    }
}

/// Shelf titles and empty-shelf placeholders. English by default; the app may pass localized text.
public nonisolated struct HomeShelfMessages: Hashable, Sendable {
    public var favoritesTitle = "Favorites"
    public var liveChannelsTitle = "Live TV Channels"
    public var recordingNowTitle = "Recording Now"
    public var recentRecordingsTitle = "Recent Recordings"
    public var continueWatchingTitle = "Continue Watching"
    public var quickPlayHistoryTitle = "Quick Play History"
    public var libraryTitle = "Library"
    /// Favorites and Live TV Channels when no source offers live TV.
    public var noLiveTVSource = "No Live TV source configured"
    public var noFavorites = "No favorite channels yet"
    public var noChannels = "No channels found"
    /// Recent Recordings when no source offers recordings.
    public var noDVRSource = "Connect a DVR source in Settings"
    public var noRecordings = "No recordings yet"
    /// Quick Play History while the history is empty (cleared, or not saved).
    public var noQuickPlayHistory = "No Quick Play history yet"
    /// A pinned library section with nothing in it.
    public var emptyLibrary = "Nothing in this library yet"
    /// A shelf whose every source failed: Local Network access is off (the app links to Settings).
    public var localNetworkDenied = "Local Network access is off"
    /// A shelf whose every source failed and gave no reason of its own.
    public var sourceUnreachable = "Can't reach this source right now"
    /// A shelf whose every source needs the user to sign in again.
    public var signInRequired = "Sign in again in Settings"

    public init() {}

    func title(for kind: HomeShelfKind) -> String {
        switch kind {
        case .favorites: favoritesTitle
        case .liveChannels: liveChannelsTitle
        case .recordingNow: recordingNowTitle
        case .recentRecordings: recentRecordingsTitle
        case .continueWatching: continueWatchingTitle
        case .quickPlayHistory: quickPlayHistoryTitle
        case .library: libraryTitle
        }
    }
}
