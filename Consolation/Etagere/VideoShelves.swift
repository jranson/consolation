//
//  VideoShelves.swift
//  Consolation
//
//  The Etagere as Consolation uses it: specialized to VideoCard. Consolation code names only these typealiases; the
//  `etagere_video_cards_only` lint rule rejects any other specialization.
//

import EtagereKit
import MediaSourceKit

typealias VideoShelf = Shelf<VideoCard>
typealias VideoShelfState = ShelfState<VideoCard>
typealias VideoEtagere = Etagere<VideoCard>
typealias VideoEtagereModel = EtagereModel<VideoCard>
/// The Active Shelf and each shelf's anchored card, saved between launches.
typealias VideoEtagerePosition = EtagerePosition<VideoCard.ID>

nonisolated extension Shelf where Card == VideoCard {
    /// One composed Home shelf as a shelf of cards. An empty shelf keeps its placeholder text, and a shelf whose source
    /// missed its soft timeout says "Updating" after its title.
    /// - Parameters:
    ///   - isAppFavorite: whether an item is a favorite kept in the app, for its card's heart.
    ///   - leadingCards: cards the app puts before the shelf's items (the Capture Card card in Favorites).
    static func home(_ shelf: HomeShelf, isAppFavorite: (MediaItemID) -> Bool = { _ in false },
                     leadingCards: [VideoCard] = []) -> VideoShelf {
        VideoShelf(
            id: shelf.id,
            title: shelf.title,
            cards: leadingCards + shelf.items.map { VideoCard.make(from: $0, isAppFavorite: isAppFavorite($0.id)) },
            emptyMessage: shelf.emptyMessage,
            isUpdating: shelf.isUpdating
        )
    }
}
