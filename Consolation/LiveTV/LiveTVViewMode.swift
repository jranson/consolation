//
//  LiveTVViewMode.swift
//  Consolation
//
//  The "View:" pill above the Live TV grid. ♥ Only is the default; a change is remembered.
//

import Foundation

enum LiveTVViewMode: String, CaseIterable, Identifiable {
    case favoritesOnly
    case favoritesFirst
    case byChannel

    static let storageKey = AppIdentifier.scoped("liveTV.viewMode")
    static let defaultMode: LiveTVViewMode = .favoritesOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .favoritesOnly: "Only"
        case .favoritesFirst: "First"
        case .byChannel: "By Channel"
        }
    }

    /// The ♥ options show the heart.fill symbol before their label.
    var showsHeart: Bool { self != .byChannel }

    /// Applies the view to channels already sorted by channel number.
    func apply(to channels: [LiveChannel]) -> [LiveChannel] {
        switch self {
        case .favoritesOnly:
            return channels.filter(\.favorite.isFavorite)
        case .favoritesFirst:
            return channels.filter(\.favorite.isFavorite) + channels.filter { !$0.favorite.isFavorite }
        case .byChannel:
            return channels
        }
    }
}
