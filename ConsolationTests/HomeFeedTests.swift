import Foundation
import HTTPMPEG2Kit
import MediaSourceKit
import Testing
@testable import Consolation

/// What Home learns from this device alone: resume positions (capped, never for live channels), local favorites,
/// and Settings › Home (Quick Play History off by default). No network, no real storage.
@MainActor
struct HomeFeedTests {
    static let movie = MediaItemID(source: .quickPlay, key: "url:0001")
    static let clip = MediaItemID(source: .quickPlay, key: "url:0002")

    // MARK: - Resume positions

    @Test func resumePositionsAreNewestFirstAndPersist() {
        let documents = DefaultsDocumentStore(defaults: TestDefaults.make())
        let store = ResumeStore(documents: documents)
        store.record(Self.movie, position: .seconds(60), duration: .seconds(600), at: Date(timeIntervalSince1970: 1))
        store.record(Self.clip, position: .seconds(30), duration: nil, at: Date(timeIntervalSince1970: 2))
        store.record(Self.movie, position: .seconds(90), duration: .seconds(600), at: Date(timeIntervalSince1970: 3))
        #expect(store.points.map(\.item) == [Self.movie, Self.clip])
        #expect(store.point(for: Self.movie)?.progress.position == .seconds(90))
        #expect(abs((store.point(for: Self.movie)?.progress.fraction ?? 0) - 0.15) < 0.000_1)
        #expect(ResumeStore(documents: documents).points == store.points)
    }

    @Test func resumePositionsAreCappedSkipTheStartAndFinishNearTheEnd() {
        let store = ResumeStore(documents: DefaultsDocumentStore(defaults: TestDefaults.make()))
        store.record(Self.movie, position: .seconds(5), duration: .seconds(600))
        #expect(store.points.isEmpty)
        store.record(Self.movie, position: .seconds(580), duration: .seconds(600))
        #expect(store.point(for: Self.movie)?.progress.isFinished == true)
        #expect(store.unfinished.isEmpty)
        store.record(Self.clip, position: .seconds(20), duration: nil)
        store.markFinished(Self.clip)
        #expect(store.point(for: Self.clip)?.progress.isFinished == true)
        #expect(store.point(for: Self.clip)?.progress.position == .seconds(20))

        for index in 0..<(ResumeStore.maxEntries + 5) {
            store.record(MediaItemID(source: .quickPlay, key: "url:\(index)"), position: .seconds(30), duration: nil)
        }
        #expect(store.points.count == ResumeStore.maxEntries)
        #expect(store.points.first?.item.key == "url:\(ResumeStore.maxEntries + 4)")
    }

    @Test func liveChannelsNeverGetAResumePosition() throws {
        let store = ResumeStore(documents: DefaultsDocumentStore(defaults: TestDefaults.make()))
        let channel = MediaItemID(channel: ChannelKey(source: "Antenna", guideNumber: "9.1"))
        store.record(channel, position: .seconds(600), duration: nil)
        store.markFinished(channel)
        #expect(store.points.isEmpty)

        let live = LiveChannel(key: "tvch:Antenna:9.1", guideNumber: "9.1", name: "KCCC",
                               streamURL: TunerFixture.url(TunerFixture.antennaHost, "9.1"), isHD: true,
                               favorite: .none)
        #expect(ResumeRecorder.itemID(for: .channel(live)) == nil)
        let url = try #require(URL(string: "https://streams.example.com/vod/movie.mp4?token=s3cr3t"))
        let item = try #require(ResumeRecorder.itemID(for: .url(url)))
        #expect(item.source == .quickPlay)
        #expect(item.key == QuickPlaySource.itemKey(for: url))
        #expect(!item.cardID.contains("example.com") && !item.cardID.contains("s3cr3t"))
    }

    @Test func quickPlayPositionsFollowTheHistory() {
        let store = ResumeStore(documents: DefaultsDocumentStore(defaults: TestDefaults.make()))
        let other = MediaItemID(source: SourceID(raw: "plex:0f0e"), key: "plex:1")
        store.record(Self.movie, position: .seconds(60), duration: nil)
        store.record(Self.clip, position: .seconds(60), duration: nil)
        store.record(other, position: .seconds(60), duration: nil)
        store.retain(source: .quickPlay, keys: [Self.clip.key])
        #expect(Set(store.points.map(\.item)) == [Self.clip, other])
    }

    // MARK: - Settings › Home

    @Test func homeSettingsDefaultToQuickPlayHistoryOffAndPersist() {
        let defaults = TestDefaults.make()
        let settings = HomeSettings(defaults: defaults)
        #expect(settings.configuration == .default)
        #expect(!settings.isEnabled(.quickPlayHistory))
        #expect(settings.isEnabled(.favorites))
        settings.setEnabled(.recentRecordings, false)
        settings.move(fromOffsets: [4], toOffset: 0)
        let library = HomeShelfKind.library(SourceID(raw: "plex:0f0e"), sectionKey: "1")
        settings.setEnabled(library, true)

        let reloaded = HomeSettings(defaults: defaults)
        #expect(reloaded.shelves == settings.shelves)
        #expect(reloaded.shelves.first?.kind == .continueWatching)
        #expect(!reloaded.isEnabled(.recentRecordings))
        #expect(reloaded.shelves.last == HomeShelfSetting(kind: library))
        reloaded.unpin(library)
        reloaded.reset()
        #expect(reloaded.configuration == .default)
    }

    @Test func savedSettingsGainNewShelvesInTheirDefaultPlace() {
        let saved = [HomeShelfSetting(kind: .liveChannels, isEnabled: false), HomeShelfSetting(kind: .favorites),
                     HomeShelfSetting(kind: .liveChannels)]
        let normalized = HomeSettings.normalized(saved)
        #expect(normalized.map(\.kind) == [.liveChannels, .favorites, .recordingNow, .recentRecordings,
                                           .continueWatching, .quickPlayHistory])
        #expect(normalized.first?.isEnabled == false)
        #expect(normalized.last?.isEnabled == false)
    }

    // MARK: - Feeding the composer

    @Test func localFavoritesResumePositionsAndSettingsReachTheComposer() {
        let world = SourcesWorld()
        world.favorites.toggle("tvch:Antenna:20.4")
        world.favorites.toggle("tvch:Antenna:4.1")
        world.favorites.toggle("not-a-channel-key")
        world.resumePositions.record(Self.movie, position: .seconds(60), duration: .seconds(600))
        world.resumePositions.record(Self.clip, position: .seconds(599), duration: .seconds(600))
        world.settings.setEnabled(.quickPlayHistory, true)
        world.home.apply()
        #expect(world.composer.localState.favorites == [
            MediaItemID(channel: ChannelKey(source: "Antenna", guideNumber: "4.1")),
            MediaItemID(channel: ChannelKey(source: "Antenna", guideNumber: "20.4"))
        ])
        #expect(world.composer.localState.resumePoints.map(\.item) == [Self.movie])
        #expect(world.composer.configuration == world.settings.configuration)
        #expect(world.composer.configuration.shelves.contains(HomeShelfSetting(kind: .quickPlayHistory)))
    }

    /// Privacy default: Home is visible to others in a living room and Quick Play names come from URLs that can
    /// carry tokens, so Quick Play videos join Continue Watching only while the Quick Play History shelf is on.
    @Test func quickPlayStaysOutOfContinueWatchingUntilItsShelfIsOn() async throws {
        let world = SourcesWorld()
        let url = try #require(URL(string: "https://streams.example.com/vod/movie.mp4?token=s3cr3t"))
        world.history.record(url)
        await world.registry.syncHistory().value
        let item = MediaItemID(source: .quickPlay, key: QuickPlaySource.itemKey(for: url))
        let other = MediaItemID(source: SourceID(raw: "plex:0f0e"), key: "plex:1")
        world.resumePositions.record(item, position: .seconds(60), duration: .seconds(600))
        world.resumePositions.record(other, position: .seconds(60), duration: .seconds(600))
        world.home.apply()
        #expect(world.composer.localState.resumePoints.map(\.item) == [other])
        await world.home.appear()
        #expect(world.composer.shelf(.continueWatching) == nil)
        #expect(world.composer.shelf(.quickPlayHistory) == nil)

        world.settings.setEnabled(.quickPlayHistory, true)
        world.home.apply()
        #expect(world.composer.localState.resumePoints.map(\.item) == [other, item])
        #expect(await waitUntil { world.composer.shelf(.continueWatching)?.items.map(\.id) == [item] })
        #expect(HomeModel.continueWatching(world.resumePositions.unfinished, showsQuickPlay: false).map(\.item)
            == [other])
    }

    @Test func theComposerFollowsChangesOnItsOwn() async {
        let world = SourcesWorld()
        world.favorites.toggle("tvch:Antenna:9.1")
        #expect(await waitUntil { world.composer.localState.favorites.count == 1 })
        world.settings.setEnabled(.favorites, false)
        #expect(await waitUntil { world.composer.configuration == world.settings.configuration })
    }
}
