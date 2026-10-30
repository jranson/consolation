//
//  HomeEtagere.swift
//  Consolation
//
//  One window's Home Etagere: its model, kept for the window's life so switching panes keeps every shelf's rotation and
//  the Active Shelf, fed from Home's composed shelves; and the position saved between launches, one for the whole app,
//  restored once per window as the shelves arrive.
//

import EtagereKit
import Foundation
import MediaSourceKit
import Observation

@Observable
final class HomeEtagere {
    let model: VideoEtagereModel
    @ObservationIgnored private let positions: HomePositionStore
    @ObservationIgnored private var hasLoadedPosition = false
    /// The parts of the saved position not restored yet: shelves and cards that haven't arrived. Dropped once the
    /// first refresh is done, or as soon as the user moves.
    @ObservationIgnored private(set) var pendingPosition: VideoEtagerePosition?
    /// The position right after the last update, to tell the user's moves from content changes.
    @ObservationIgnored private var positionAfterUpdate: VideoEtagerePosition?
    /// The user moved since launch: the Etagere's own position is a choice, not just where it started.
    @ObservationIgnored private var userHasMoved = false
    @ObservationIgnored private var lastSaved: VideoEtagerePosition?

    init(positions: HomePositionStore, configuration: EtagereConfiguration = EtagereConfiguration()) {
        self.positions = positions
        model = VideoEtagereModel(shelves: [], configuration: configuration)
    }

    /// Takes Home's latest shelves (the selection stays put) and restores what it can of the saved position.
    /// - Parameters:
    ///   - isAppFavorite: whether an item is a favorite kept in the app, for its card's heart.
    ///   - favoritesLeadingCards: cards that go first in Favorites (the Capture Card card).
    func update(_ shelves: [HomeShelf], isAppFavorite: (MediaItemID) -> Bool,
                favoritesLeadingCards: [VideoCard] = []) {
        if !hasLoadedPosition {
            hasLoadedPosition = true
            pendingPosition = positions.load()
        }
        if noteUserMoves(), pendingPosition != nil {
            // The user moved since the last update: their choice wins over the saved position.
            pendingPosition = nil
        }
        let favoritesID = HomeShelfKind.favorites.stableID
        model.replaceShelves(shelves.map { shelf in
            VideoShelf.home(shelf, isAppFavorite: isAppFavorite,
                            leadingCards: shelf.id == favoritesID ? favoritesLeadingCards : [])
        })
        restorePending()
        positionAfterUpdate = model.position
    }

    /// Settings › Home changed, or the pane's width did.
    func configure(_ configuration: EtagereConfiguration) {
        if model.configuration != configuration { model.configuration = configuration }
    }

    /// Home's first refresh is done: what hasn't arrived by now isn't restored.
    func finishRestoring() {
        pendingPosition = nil
    }

    /// Saves where the user is (Home disappeared, or the app is going to the background). Parts of the saved
    /// position still waiting for their shelf are kept: until the user moves, the saved Active Shelf and anchored
    /// cards that haven't arrived win over where the Etagere merely started; after that, only the anchors of
    /// shelves that don't exist yet are kept.
    func savePosition() {
        guard hasLoadedPosition else { return }
        noteUserMoves()
        var position = model.position
        if let pendingPosition {
            if let activeID = pendingPosition.activeShelfID, !userHasMoved || position.activeShelfID == nil {
                position.activeShelfID = activeID
            }
            for (shelfID, cardID) in pendingPosition.anchoredCardIDs
            where !userHasMoved || model.shelf(id: shelfID) == nil {
                position.anchoredCardIDs[shelfID] = cardID
            }
        }
        guard position != lastSaved else { return }
        positions.save(position)
        lastSaved = position
    }

    /// Notes whether the position changed since the last update, which only the user does. Returns true if so.
    @discardableResult
    private func noteUserMoves() -> Bool {
        guard let positionAfterUpdate, model.position != positionAfterUpdate else { return false }
        userHasMoved = true
        return true
    }

    /// Restores the parts of the pending position whose shelf (and card) exist now, and keeps the rest pending.
    private func restorePending() {
        guard var pending = pendingPosition else { return }
        var now = VideoEtagerePosition()
        for (shelfID, cardID) in pending.anchoredCardIDs
        where model.shelf(id: shelfID)?.cards.contains(where: { $0.id == cardID }) == true {
            now.anchoredCardIDs[shelfID] = cardID
            pending.anchoredCardIDs[shelfID] = nil
        }
        if let activeID = pending.activeShelfID, model.shelf(id: activeID) != nil {
            now.activeShelfID = activeID
            pending.activeShelfID = nil
        }
        if now.activeShelfID != nil || !now.anchoredCardIDs.isEmpty { model.restore(now) }
        pendingPosition = pending.activeShelfID == nil && pending.anchoredCardIDs.isEmpty ? nil : pending
    }
}

/// The app-wide Home position: a small JSON document (a UserDefaults entry on tvOS). It holds shelf and card IDs only,
/// which never contain a host, DeviceID or URL.
final class HomePositionStore {
    private static let documentName = "home-position"
    private let documents: any DocumentStore

    init(documents: any DocumentStore = DocumentStores.platformDefault()) {
        self.documents = documents
    }

    func load() -> VideoEtagerePosition? {
        documents.load(VideoEtagerePosition.self, named: Self.documentName)
    }

    func save(_ position: VideoEtagerePosition) {
        documents.save(position, named: Self.documentName)
    }
}
