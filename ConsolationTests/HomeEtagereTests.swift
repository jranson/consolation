import EtagereKit
import Foundation
import HTTPMPEG2Kit
import MediaSourceKit
import Testing
@testable import Consolation

/// Home's Etagere in a window: the saved position restored as the shelves arrive and saved with what is still on its
/// way, and Settings › Home turned into the Etagere's configuration. No views, no network.
@MainActor
struct HomeEtagereTests {
    nonisolated static func channel(_ guideNumber: String) -> MediaItem {
        let id = MediaItemID(channel: ChannelKey(source: "Antenna", guideNumber: guideNumber))
        return MediaItem(id: id, kind: .channel(number: guideNumber, callSign: "K\(guideNumber)", isHD: true,
                                                isFavorite: false), title: "K\(guideNumber)")
    }

    nonisolated static func clip(_ key: String) -> MediaItem {
        MediaItem(id: MediaItemID(source: .quickPlay, key: key), kind: .clip, title: key)
    }

    static let placeholders = [
        HomeShelf(kind: .favorites, title: "Favorites", items: [], emptyMessage: "No favorite channels yet"),
        HomeShelf(kind: .liveChannels, title: "Live TV Channels", items: [])
    ]

    static let loaded = [
        HomeShelf(kind: .favorites, title: "Favorites", items: [], emptyMessage: "No favorite channels yet"),
        HomeShelf(kind: .liveChannels, title: "Live TV Channels", items: ["2.1", "4.1", "9.1"].map(channel))
    ]

    static let saved = VideoEtagerePosition(activeShelfID: "liveChannels", anchoredCardIDs: [
        "liveChannels": "hdhr-live:Antenna:ch:9.1", "continueWatching": "quickplay:url:0002"
    ])

    static func makeStore() -> HomePositionStore {
        HomePositionStore(documents: DefaultsDocumentStore(defaults: TestDefaults.make()))
    }

    @Test func theSavedPositionIsRestoredAsShelvesArrive() {
        let store = Self.makeStore()
        store.save(Self.saved)
        let etagere = HomeEtagere(positions: store)

        // The snapshot has only placeholders yet: the active shelf comes back at once, the cards wait.
        etagere.update(Self.placeholders) { _ in false }
        #expect(etagere.model.activeShelf?.id == "liveChannels")
        #expect(etagere.pendingPosition?.anchoredCardIDs.count == 2)

        etagere.update(Self.loaded) { _ in false }
        #expect(etagere.model.activeCard?.id == "hdhr-live:Antenna:ch:9.1")
        #expect(etagere.pendingPosition == VideoEtagerePosition(anchoredCardIDs: [
            "continueWatching": "quickplay:url:0002"
        ]))

        // Continue Watching shows up later (its items are looked up one by one) and gets its card back.
        let resumed = HomeShelf(kind: .continueWatching, title: "Continue Watching",
                                items: ["url:0001", "url:0002"].map(Self.clip))
        etagere.update(Self.loaded + [resumed]) { _ in false }
        #expect(etagere.model.shelf(id: "continueWatching")?.anchoredCard?.id == "quickplay:url:0002")
        #expect(etagere.pendingPosition == nil)
        #expect(etagere.model.activeShelf?.id == "liveChannels")
    }

    @Test func theUsersMoveWinsOverThePendingPosition() {
        let store = Self.makeStore()
        store.save(Self.saved)
        let etagere = HomeEtagere(positions: store)
        etagere.update(Self.loaded) { _ in false }
        #expect(etagere.model.activeCard?.id == "hdhr-live:Antenna:ch:9.1")

        etagere.model.move(.nextShelf, isRepeat: false, reduceMotion: true)
        let resumed = HomeShelf(kind: .continueWatching, title: "Continue Watching",
                                items: ["url:0001", "url:0002"].map(Self.clip))
        etagere.update(Self.loaded + [resumed]) { _ in false }
        #expect(etagere.pendingPosition == nil)
        #expect(etagere.model.shelf(id: "continueWatching")?.anchoredCard?.id == "quickplay:url:0001")
        #expect(etagere.model.activeShelf?.id == "favorites")
    }

    @Test func savingKeepsWhatIsStillOnItsWay() throws {
        let store = Self.makeStore()
        store.save(Self.saved)
        let etagere = HomeEtagere(positions: store)
        // Nothing loaded yet: saving now must not forget the saved position.
        etagere.savePosition()
        #expect(store.load() == Self.saved)

        etagere.update(Self.loaded) { _ in false }
        etagere.model.move(.previousCard, isRepeat: false, reduceMotion: true)
        etagere.savePosition()
        let written = try #require(store.load())
        #expect(written.activeShelfID == "liveChannels")
        #expect(written.anchoredCardIDs["liveChannels"] == "hdhr-live:Antenna:ch:4.1")
        #expect(written.anchoredCardIDs["continueWatching"] == "quickplay:url:0002")

        // Once the first refresh is done, what never arrived is dropped.
        etagere.finishRestoring()
        etagere.savePosition()
        #expect(store.load()?.anchoredCardIDs["continueWatching"] == nil)

        // A new window restores the app-wide position.
        let other = HomeEtagere(positions: store)
        other.update(Self.loaded) { _ in false }
        #expect(other.model.activeCard?.id == "hdhr-live:Antenna:ch:4.1")
    }

    /// Until the user moves, a saved Active Shelf (and anchored card) that hasn't arrived yet is what gets saved again,
    /// even while other shelves already show; once the user moves, their position wins.
    @Test func savingKeepsAPendingActiveShelfUntilTheUserMoves() throws {
        let store = Self.makeStore()
        let saved = VideoEtagerePosition(activeShelfID: "continueWatching", anchoredCardIDs: [
            "liveChannels": "hdhr-live:Antenna:ch:20.4", "continueWatching": "quickplay:url:0002"
        ])
        store.save(saved)
        let etagere = HomeEtagere(positions: store)

        // Favorites and Live TV Channels are here (Live TV Channels without 20.4 yet); Continue Watching isn't.
        etagere.update(Self.loaded) { _ in false }
        #expect(etagere.model.activeShelf?.id == "favorites")
        etagere.savePosition()
        #expect(store.load() == saved)

        // The user moves: from now on the Etagere's own position is saved, except for shelves still missing.
        etagere.model.move(.nextShelf, isRepeat: false, reduceMotion: true)
        etagere.savePosition()
        let written = try #require(store.load())
        #expect(written.activeShelfID == "liveChannels")
        #expect(written.anchoredCardIDs["liveChannels"] == "hdhr-live:Antenna:ch:2.1")
        #expect(written.anchoredCardIDs["continueWatching"] == "quickplay:url:0002")
    }

    @Test func homeSettingsBecomeTheEtagereConfiguration() {
        let defaults = TestDefaults.make()
        let settings = HomeSettings(defaults: defaults)
        let initial = settings.etagereConfiguration(containerWidth: 1200)
        #expect(initial.horizontalAlignment == .leading)
        #expect(initial.verticalMode == .ring)
        #expect(initial.verticalAlignment == .top)
        #expect(initial.metrics == .automatic)
        #expect(initial.showsSeam && initial.showsShelfSeam)

        settings.shelfAlignment = .center
        settings.verticalMode = .cursor
        settings.verticalAlignment = .bottom
        settings.cardSize = .large
        settings.showsSeam = false
        let changed = settings.etagereConfiguration(containerWidth: 1200)
        #expect(changed.horizontalAlignment == .center)
        #expect(changed.verticalMode == .cursor)
        #expect(changed.verticalAlignment == .bottom)
        #expect(!changed.showsSeam && !changed.showsShelfSeam)
        #expect(changed.metrics == HomeCardSize.large.metrics(containerWidth: 1200))

        let reloaded = HomeSettings(defaults: defaults)
        #expect(reloaded.etagereConfiguration(containerWidth: 1200) == changed)
    }

    @Test func cardSizesScaleTheStartingCardWidth() {
        let regular = EtagereMetrics.automatic.resolved(containerWidth: 1200, isTelevision: false)
        #expect(HomeCardSize.medium.metrics(containerWidth: 1200, isTelevision: false) == .automatic)
        #expect(HomeCardSize.large.metrics(containerWidth: nil, isTelevision: false) == .automatic)

        let large = HomeCardSize.large.metrics(containerWidth: 1200, isTelevision: false)
            .resolved(containerWidth: 1200, isTelevision: false)
        #expect(large.cardWidth == (regular.cardWidth * 1.2).rounded())
        #expect(large.widthClass == .regular)
        #expect(large.cardSpacing == regular.cardSpacing)
        #expect(large.activeScale == regular.activeScale)

        let television = HomeCardSize.small.metrics(containerWidth: 1920, isTelevision: true)
            .resolved(containerWidth: 1920, isTelevision: true)
        #expect(television.widthClass == .television)
        #expect(television.cardWidth == 288)
    }
}
