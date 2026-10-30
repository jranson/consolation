import EtagereKit
import Foundation
import HTTPMPEG2Kit
import MediaSourceKit
import Testing
@testable import Consolation

/// VideoCard factories over fixtures, never the network. Card IDs are stable and never hold a DeviceID, host, IP
/// address or URL; Favorites keeps only favorites; empty shelves carry their message; every MediaItem kind becomes a
/// card.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct VideoCardTests {
    /// What no card ID may contain: the fixture tuners' addresses, DeviceIDs, names and stream URLs.
    static let deviceDetails = [
        TunerFixture.antennaHost, TunerFixture.cableHost, "192.0.2.", "1A2B3C4D", "1a2b3c4d", "0C0FFEE0",
        "Test Tuner", ":5004", "http", "/auto/"
    ]

    static func channel(_ guideNumber: String) -> MediaItemID {
        MediaItemID(channel: ChannelKey(source: "Antenna", guideNumber: guideNumber))
    }

    @Test func liveCardsHaveStableIDsWithoutDeviceDetails() async throws {
        let world = SourcesWorld(tuners: FakeTuners([TunerFixture.antennaHost: TunerFixture.antenna]))
        world.addTuner(TunerFixture.antennaHost)
        await world.home.appear()
        let shelf = try #require(world.composer.shelf(.liveChannels))
        let cards = VideoShelf.home(shelf).cards

        #expect(cards.map(\.id) == ["2.1", "4.1", "9.1", "20.4"].map { "hdhr-live:Antenna:ch:\($0)" })
        #expect(cards.map(\.id) == ["2.1", "4.1", "9.1", "20.4"].map { Self.channel($0).cardID })
        for card in cards {
            for detail in Self.deviceDetails {
                #expect(!card.id.contains(detail), "\(card.id) contains \(detail)")
            }
            #expect(card.kind == .liveChannel)
            #expect(card.badge == .live)
            // Live channel cards never show a tuned or captured frame.
            #expect(card.artworkURL == nil)
            #expect(card.progress == nil)
            #expect(card.playable.item.cardID == card.id)
        }

        let kccc = try #require(cards.first { $0.subtitle == "9.1" })
        #expect(kccc.title == "KCCC")
        #expect(kccc.isHD)
        #expect(kccc.favorite == .none)
        #expect(kccc.playable.item == Self.channel("9.1"))
        #expect(kccc.accessibilityTitle == "KCCC 9.1, HD, live now")
        #expect(cards.first { $0.subtitle == "20.4" }?.accessibilityTitle == "KDDD 20.4, live now")

        // A later launch (a new world over the same fixture) makes the same cards with the same faces.
        let again = SourcesWorld(tuners: FakeTuners([TunerFixture.antennaHost: TunerFixture.antenna]))
        again.addTuner(TunerFixture.antennaHost)
        await again.home.appear()
        let laterCards = try VideoShelf.home(#require(again.composer.shelf(.liveChannels))).cards
        #expect(laterCards == cards)
        #expect(laterCards.map(\.generatedHue) == cards.map(\.generatedHue))
        #expect(cards.allSatisfy { (0..<1).contains($0.generatedHue) })
    }

    @Test func favoritesKeepOnlyDeviceAndAppFavoritesOnce() async throws {
        let world = SourcesWorld(tuners: FakeTuners([TunerFixture.antennaHost: TunerFixture.antenna]))
        world.addTuner(TunerFixture.antennaHost)
        // 2.1 is a favorite on the device ("Favorite":1); 4.1 only in the app; 2.1 is also marked in the app, as
        // happens until the next lineup load reconciles it.
        world.favorites.toggle("tvch:Antenna:4.1")
        world.favorites.toggle("tvch:Antenna:2.1")
        world.home.apply()
        await world.home.appear()
        let keys = world.favorites.keys
        let favorites = try #require(world.composer.shelf(.favorites))
        let shelf = VideoShelf.home(favorites) { id in id.channelKey.map { keys.contains($0.stringValue) } ?? false }

        #expect(shelf.id == "favorites")
        #expect(shelf.cards.map(\.subtitle) == ["2.1", "4.1"])
        #expect(shelf.cards.map(\.favorite) == [.device, .app])
        #expect(shelf.cards.map(\.favoriteSymbol) == ["lock.heart.fill", "heart.fill"])
        #expect(shelf.cards.map(\.accessibilityTitle) == ["KAAA 2.1, HD, live now, favorite",
                                                          "KBBB 4.1, HD, live now, favorite"])
        #expect(Set(shelf.cards.map(\.id)).count == shelf.cards.count)
        #expect(shelf.emptyMessage == nil)

        // Live TV Channels marks the same favorites and nothing else.
        let channels = try VideoShelf.home(#require(world.composer.shelf(.liveChannels))) { id in
            id.channelKey.map { keys.contains($0.stringValue) } ?? false
        }
        #expect(channels.cards.map(\.favorite) == [.device, .app, .none, .none])
    }

    @Test func emptyShelvesKeepTheirMessage() async throws {
        let world = SourcesWorld()
        await world.home.appear()
        let shelves = world.composer.shelves.map { VideoShelf.home($0) }

        #expect(shelves.map(\.id) == ["favorites", "liveChannels", "recentRecordings"])
        #expect(shelves.allSatisfy { $0.cards.isEmpty })
        #expect(shelves.map(\.emptyMessage) == ["No Live TV source configured", "No Live TV source configured",
                                                "Connect a DVR source in Settings"])
        #expect(shelves.map(\.title) == ["Favorites", "Live TV Channels", "Recent Recordings"])

        // An empty shelf stays navigable, and "go" on it runs the host's action for that shelf.
        let model = VideoEtagereModel(shelves: shelves)
        #expect(model.activation == .emptyShelf(shelfID: "favorites"))
        #expect(model.shelf(id: "liveChannels")?.emptyMessage == "No Live TV source configured")
    }

    @Test func quickPlayCardsHideTheirURL() async throws {
        let url = try #require(URL(string: "https://streams.example.com/vod/movie.mp4?token=s3cr3t"))
        let source = QuickPlaySource(history: [QuickPlayHistoryEntry(url: url, lastPlayed: .now)])
        var item = try await source.item(source.itemID(for: url))
        item.progress = PlaybackProgress(position: .seconds(150), duration: .seconds(600), updatedAt: .now)
        let card = VideoCard.make(from: item)

        #expect(card.kind == .quickPlay)
        #expect(card.id == "quickplay:" + QuickPlaySource.itemKey(for: url))
        for secret in ["example.com", "s3cr3t", "movie", "https"] {
            #expect(!card.id.contains(secret))
        }
        #expect(card.title == "movie.mp4")
        #expect(card.subtitle == "streams.example.com")
        #expect(card.progress == 0.25)
        #expect(card.artworkURL == nil)
        #expect(card.badge == nil)
        #expect(card.favorite == .none)
        #expect(card.accessibilityTitle == "movie.mp4, streams.example.com, 25% watched")
    }

    @Test func everyItemKindBecomesACard() throws {
        let plex = SourceID(raw: "plex:0f0e")
        let art = try #require(URL(string: "https://media.example.com/art/1.jpg"))
        func item(_ key: String, _ kind: MediaItem.Kind, title: String = "Title", subtitle: String? = nil,
                  artwork: Artwork = Artwork()) -> MediaItem {
            MediaItem(id: MediaItemID(source: plex, key: key), kind: kind, title: title, subtitle: subtitle,
                      artwork: artwork)
        }

        let recording = VideoCard.make(from: item(
            "plex:1", .recording(airedAt: nil, recordedAt: nil, inProgress: true, channel: "KCCC"),
            artwork: Artwork(thumb: .remote(art, headerKeys: []))))
        #expect(recording.kind == .recording)
        #expect(recording.badge == .recordingNow)
        #expect(recording.subtitle == "KCCC")
        #expect(recording.artworkURL == art)
        #expect(recording.accessibilityTitle == "Title, KCCC, recording now")

        // Artwork that needs an auth header waits for the app's image loader: the generated face shows.
        let signedIn = VideoCard.make(from: item(
            "plex:2", .recording(airedAt: nil, recordedAt: nil, inProgress: false, channel: nil),
            artwork: Artwork(thumb: .remote(art, headerKeys: ["X-Plex-Token"]))))
        #expect(signedIn.artworkURL == nil)
        #expect(signedIn.badge == nil)

        let movie = VideoCard.make(from: item("plex:3", .movie(year: 1999)), isAppFavorite: true)
        #expect(movie.kind == .movie)
        #expect(movie.subtitle == "1999")
        #expect(movie.favorite == .app)

        let episode = VideoCard.make(from: item("plex:4", .episode(series: "Show", season: 2, episode: 5,
                                                                   airDate: nil)))
        #expect(episode.kind == .episode)
        #expect(episode.subtitle == "Show · S2 E5")

        for kind in [MediaItem.Kind.series, .season(1), .folder] {
            #expect(VideoCard.make(from: item("plex:c", kind, subtitle: "Shelf")).kind == .collection)
        }
        for kind in [MediaItem.Kind.file, .clip] {
            let card = VideoCard.make(from: item("plex:v", kind, subtitle: "Folder"))
            #expect(card.kind == .video)
            #expect(card.subtitle == "Folder")
            #expect(!card.isHD)
        }
    }
}
