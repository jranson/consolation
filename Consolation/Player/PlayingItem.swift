//
//  PlayingItem.swift
//  Consolation
//
//  What a player session plays: a live channel, a Quick Play URL, or an item from a library source (a recording,
//  a movie, a server's live channel) already turned into an engine input.
//

import Foundation
import MediaSourceKit

/// What a player session is playing.
nonisolated enum PlayingItem: Hashable, Sendable {
    case channel(LiveChannel)
    case url(URL)
    case media(SourceMedia)

    var title: String {
        switch self {
        case .channel(let channel): channel.displayName
        case .url(let url): url.lastPathComponent.isEmpty ? (url.host() ?? url.absoluteString) : url.lastPathComponent
        case .media(let media): media.subtitle.map { "\(media.title): \($0)" } ?? media.title
        }
    }

    /// For the system's Now Playing: the episode as the title and the show under it, when an item has both.
    var nowPlayingNames: (title: String, subtitle: String?) {
        switch self {
        case .channel(let channel): (channel.displayName, String(localized: "Channel \(channel.guideNumber)"))
        case .url: (title, nil)
        case .media(let media): media.subtitle.map { ($0, media.title) } ?? (media.title, nil)
        }
    }

    var isLive: Bool {
        switch self {
        case .channel: true
        case .url: false
        case .media(let media): media.isLive
        }
    }

    /// An identifier for the system's Now Playing; never the URL itself, which can carry tokens.
    var id: String {
        switch self {
        case .channel(let channel): "channel:\(channel.key)"
        case .url(let url): "url:\(String(UInt(bitPattern: url.absoluteString.hashValue), radix: 36))"
        case .media(let media): "media:\(media.item.cardID)"
        }
    }
}

/// A library source's item, ready to play: its identity and names, and the engine input its source's descriptor
/// mapped to. The input may hold a short-lived media URL, so it lives only in memory and never in a description.
nonisolated struct SourceMedia: Hashable, Sendable, CustomStringConvertible {
    let item: MediaItemID
    let title: String
    let subtitle: String?
    let isLive: Bool
    let input: EngineInput
    /// Each resolution is its own playback: playing the same item again restarts it.
    private let playbackID = UUID()

    init(item: MediaItemID, title: String, subtitle: String?, isLive: Bool, input: EngineInput) {
        self.item = item
        self.title = title
        self.subtitle = subtitle
        self.isLive = isLive
        self.input = input
    }

    static func == (lhs: SourceMedia, rhs: SourceMedia) -> Bool {
        lhs.item == rhs.item && lhs.playbackID == rhs.playbackID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(item)
        hasher.combine(playbackID)
    }

    var description: String { "SourceMedia(\(item.cardID))" }
}
