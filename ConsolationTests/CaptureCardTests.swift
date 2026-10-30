//
//  CaptureCardTests.swift
//  ConsolationTests
//
//  The Capture Card pane in the shell (where it sits, that it can be hidden, that the last pane is restored) and
//  the Capture Card card on Home: first in Favorites while a capture card is attached. No views, no devices.
//

import EtagereKit
import Foundation
import MediaSourceKit
import SwiftUI
import Testing
@testable import Consolation

@MainActor
struct CaptureCardTests {
    private static func defaults() -> UserDefaults {
        UserDefaults(suiteName: "ConsolationTests.\(UUID().uuidString)") ?? .standard
    }

    @Test func sitsJustAboveSettingsWithItsOwnShortcut() {
        #expect(ShellItem.captureCard.isAvailable)
        #expect(ShellItem.captureCard.placement == .trailing)
        #expect(ShellItem.captureCard.isHideable)
        #expect(ShellItem.captureCard.shortcutKey == "3")
        let items = PillSettings(defaults: Self.defaults()).visibleItems
        #expect(Array(items.suffix(2)) == [.captureCard, .settings])
    }

    @Test func choosingCaptureCardMakesItTheLaunchPane() {
        let defaults = Self.defaults()
        let settings = PillSettings(defaults: defaults)
        #expect(ShellModel(settings: settings, defaults: defaults).selection == .home)
        ShellModel(settings: settings, defaults: defaults).selection = .captureCard
        #expect(ShellModel(settings: settings, defaults: defaults).selection == .captureCard)
    }

    @Test func hidingCaptureCardRemovesItAndFallsBackToHome() {
        let defaults = Self.defaults()
        let settings = PillSettings(defaults: defaults)
        ShellModel(settings: settings, defaults: defaults).selection = .captureCard
        settings.setHidden(.captureCard, true)
        #expect(!settings.visibleItems.contains(.captureCard))
        #expect(ShellModel(settings: settings, defaults: defaults).selection == .home)
        #expect(ShellModel.restorable(.captureCard, hidden: [.captureCard]) == .home)
    }

    @Test func appleCamerasAreNotCaptureCards() {
        #expect(isFaceTimeCameraName("FaceTime HD Camera"))
        #expect(isFaceTimeCameraName("MacBook Pro Camera (FaceTime)"))
        #expect(isFaceTimeCameraName("Studio Display Camera"))
        #expect(isFaceTimeCameraName("James’s iPhone Camera"))
        #expect(!isFaceTimeCameraName("Cam Link 4K"))
        #expect(!isFaceTimeCameraName("Game Capture HD60 X"))
        #expect(!isFaceTimeCameraName("USB3.0 Capture"))
    }

    @Test func captureCardCardOpensThePaneNotThePlayer() {
        let card = VideoCard.captureCard(deviceName: "Cam Link 4K")
        #expect(card.kind == .captureCard)
        #expect(card.title == "Capture Card")
        #expect(card.subtitle == "Cam Link 4K")
        #expect(card.favorite == .none)
        #expect(card.playable.item.channelKey == nil)
    }

    @Test func captureCardGoesFirstInFavoritesOnly() {
        let documents = DefaultsDocumentStore(defaults: Self.defaults())
        let etagere = HomeEtagere(positions: HomePositionStore(documents: documents))
        let shelves = [
            HomeShelf(kind: .favorites, title: "Favorites", items: [], emptyMessage: "No favorites yet"),
            HomeShelf(kind: .liveChannels, title: "Live TV Channels", items: [])
        ]
        let card = VideoCard.captureCard(deviceName: "Cam Link 4K")
        etagere.update(shelves, isAppFavorite: { _ in false }, favoritesLeadingCards: [card])
        let favorites = etagere.model.shelf(id: HomeShelfKind.favorites.stableID)
        #expect(favorites?.cards.first?.id == VideoCard.captureCardID)
        #expect(etagere.model.shelf(id: HomeShelfKind.liveChannels.stableID)?.cards.isEmpty == true)

        etagere.update(shelves, isAppFavorite: { _ in false })
        #expect(etagere.model.shelf(id: HomeShelfKind.favorites.stableID)?.cards.isEmpty == true)
    }
}
