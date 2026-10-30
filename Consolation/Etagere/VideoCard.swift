//
//  VideoCard.swift
//  Consolation
//
//  The only card a Consolation shelf holds, and the only file that can make one: the init is `fileprivate` and declared
//  in the struct body, so Swift synthesizes no memberwise init, and every card comes from a factory below. New kinds of
//  video are new `Kind` cases and factories, never new card types. No SwiftUI here; the face is in VideoCardFace.swift.
//

import Foundation
import MediaSourceKit

/// What "go" on a card plays: the item's identity, resolved through `SourceRegistry` when the user presses Go.
nonisolated struct PlayableRef: Hashable, Sendable {
    let item: MediaItemID

    init(_ item: MediaItemID) {
        self.item = item
    }
}

nonisolated struct VideoCard: Identifiable, Hashable, Sendable {
    nonisolated enum Kind: Hashable, Sendable {
        case liveChannel
        case recording
        case movie
        case episode
        /// A file or clip from a library source.
        case video
        /// A URL played from Quick Play.
        case quickPlay
        /// A series, season or folder.
        case collection
        /// The Capture Card pane, first in Favorites while a capture card is attached. "Go" opens the pane.
        case captureCard
    }

    nonisolated enum Badge: Hashable, Sendable {
        case live
        case recordingNow
    }

    /// The favorite mark: `lock.heart.fill` for a favorite on the tuner (read-only), `heart.fill` for one kept in the
    /// app.
    nonisolated enum Favorite: Hashable, Sendable {
        case none
        case device
        case app
    }

    /// `"<SourceID.raw>:<key>"`, for example `hdhr-live:Antenna:ch:9.1`: stable across launches, and never a DeviceID,
    /// host name, IP address or URL.
    let id: String
    let kind: Kind
    /// The call sign of a live channel ("KUSA-HD"), otherwise the item's title.
    let title: String
    /// The channel number of a live channel ("9.1"); otherwise a channel, year, series or host.
    let subtitle: String?
    let badge: Badge?
    let isHD: Bool
    let favorite: Favorite
    /// Server artwork the face may load; nil draws the generated face. Always nil for live channels, which never show a
    /// tuned or captured frame.
    let artworkURL: URL?
    /// The resume position, 0...1.
    let progress: Double?
    let playable: PlayableRef

    // Declared in the struct body, so Swift does not synthesize an internal memberwise init.
    fileprivate init(id: String, kind: Kind, title: String, subtitle: String?, badge: Badge?, isHD: Bool,
                     favorite: Favorite, artworkURL: URL?, progress: Double?, playable: PlayableRef) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.isHD = isHD
        self.favorite = favorite
        self.artworkURL = artworkURL
        self.progress = progress
        self.playable = playable
    }
}

nonisolated extension VideoCard {
    /// The only way a `MediaItem` becomes a card.
    /// - Parameter isAppFavorite: the item is a favorite kept in the app. A favorite on the tuner wins over it.
    static func make(from item: MediaItem, isAppFavorite: Bool = false) -> VideoCard {
        let favorite: Favorite = item.isDeviceFavorite ? .device : (isAppFavorite ? .app : .none)
        switch item.kind {
        case let .channel(number, callSign, isHD, _):
            let name = callSign.trimmingCharacters(in: .whitespaces)
            return VideoCard(id: item.cardID, kind: .liveChannel, title: name.isEmpty ? item.title : name,
                             subtitle: number, badge: .live, isHD: isHD, favorite: favorite, artworkURL: nil,
                             progress: nil, playable: PlayableRef(item.id))
        case let .recording(_, _, inProgress, channel):
            return card(item, kind: .recording, subtitle: channel ?? item.subtitle,
                        badge: inProgress ? .recordingNow : nil, favorite: favorite)
        case let .movie(year):
            return card(item, kind: .movie, subtitle: item.subtitle ?? year.map(String.init), favorite: favorite)
        case let .episode(series, season, episode, _):
            return card(item, kind: .episode, subtitle: episodeLine(series: series, season: season,
                                                                     episode: episode), favorite: favorite)
        case .series, .season, .folder:
            return card(item, kind: .collection, subtitle: item.subtitle, favorite: favorite)
        case .file, .clip:
            let kind: Kind = item.id.source == .quickPlay ? .quickPlay : .video
            return card(item, kind: kind, subtitle: item.subtitle, favorite: favorite)
        }
    }

    /// The Capture Card card's ID, which no source's item can have (it has no `SourceID` prefix).
    static let captureCardID = "capture-card"

    /// The Capture Card pane as a Home card, showing the attached device's name. It plays nothing: Home opens the
    /// pane for it.
    static func captureCard(deviceName: String) -> VideoCard {
        VideoCard(id: captureCardID, kind: .captureCard, title: String(localized: "Capture Card"),
                  subtitle: deviceName, badge: nil, isHD: false, favorite: .none, artworkURL: nil, progress: nil,
                  playable: PlayableRef(MediaItemID(source: SourceID(raw: captureCardID), key: "device")))
    }

    /// A card for anything but a live channel: the item's own title, its artwork and its resume position.
    private static func card(_ item: MediaItem, kind: Kind, subtitle: String?, badge: Badge? = nil,
                             favorite: Favorite) -> VideoCard {
        VideoCard(id: item.cardID, kind: kind, title: item.title, subtitle: subtitle, badge: badge, isHD: false,
                  favorite: favorite, artworkURL: displayURL(item.artwork.bestLandscape),
                  progress: item.progress?.fraction, playable: PlayableRef(item.id))
    }

    /// "Series · S2 E5", or as much of it as is known.
    private static func episodeLine(series: String, season: Int?, episode: Int?) -> String {
        let number = [season.map { "S\($0)" }, episode.map { "E\($0)" }].compactMap(\.self).joined(separator: " ")
        return [series, number].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The URL a face may load for an artwork slot. Server artwork that needs an auth header waits for the app's
    /// image loader (it never goes to `AsyncImage` without its header); sidecar files, generated frames and
    /// stylized faces have no loader yet, so they draw the generated face.
    private static func displayURL(_ artwork: ArtworkRef?) -> URL? {
        guard case let .remote(url, headerKeys)? = artwork, headerKeys.isEmpty,
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url
    }
}
