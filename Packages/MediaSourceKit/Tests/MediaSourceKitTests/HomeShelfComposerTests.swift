import Foundation
import HTTPMPEG2Kit
import Testing
@testable import MediaSourceKit

/// The composer end to end: snapshot first, then refresh; the soft timeout (fired by hand, never by the clock);
/// later batches; removed sources; local favorites looked up; and no secrets in the snapshot.
@MainActor
@Suite("HomeShelfComposer", .timeLimit(.minutes(1)))
struct HomeShelfComposerTests {
    static func keys(_ shelf: HomeShelf?) -> [String] {
        shelf?.items.map(\.key) ?? []
    }

    static func snapshot(_ channels: [MediaItem]) -> HomeSnapshot {
        HomeSnapshot(sources: [SourceSnapshot(source: Sample.antenna, capabilities: [.liveTV],
                                              contributions: Sample.liveContributions(channels))])
    }

    @Test func refreshComposesWhatSourcesContribute() async {
        let live = ScriptedSource(id: Sample.antenna, kind: .hdhomerun, capabilities: [.liveTV],
                                  initial: Sample.liveContributions([Sample.channel("2.1", favorite: true),
                                                                     Sample.channel("4.1")]))
        let gate = TimeoutGate()  // never fired: every source answers in time
        let composer = HomeShelfComposer(sources: [live], sleep: gate.sleep)
        await composer.refresh()
        #expect(!composer.isRefreshing)
        #expect(Self.keys(composer.shelf(.favorites)) == ["ch:2.1"])
        #expect(Self.keys(composer.shelf(.liveChannels)) == ["ch:2.1", "ch:4.1"])
        #expect(composer.shelf(.recentRecordings)?.emptyMessage == "Connect a DVR source in Settings")
        #expect(composer.shelves.allSatisfy { !$0.isUpdating })
    }

    @Test func aSourceWithoutShelvesDoesNotHoldUpARefresh() async {
        let composer = HomeShelfComposer(sources: [ShelflessSource(id: SourceID(raw: "folder:1"))],
                                         sleep: TimeoutGate().sleep)
        await composer.refresh()
        #expect(composer.shelf(.favorites)?.emptyMessage == "No Live TV source configured")
    }

    @Test func theSnapshotRendersFirstThenTheRefreshReplacesIt() async throws {
        let store = InMemoryHomeSnapshotStore(Self.snapshot([Sample.channel("2.1", favorite: true)]))
        let live = ScriptedSource(id: Sample.antenna, kind: .hdhomerun, capabilities: [.liveTV])
        let composer = HomeShelfComposer(sources: [live], snapshotStore: store, sleep: TimeoutGate().sleep)
        await composer.loadSnapshot()
        #expect(Self.keys(composer.shelf(.favorites)) == ["ch:2.1"])
        #expect(composer.shelf(.favorites)?.isUpdating == false)

        let refresh = Task { await composer.refresh() }
        await live.publish(Sample.liveContributions([Sample.channel("2.1", favorite: true),
                                                     Sample.channel("9.1", favorite: true)]))
        await refresh.value
        #expect(Self.keys(composer.shelf(.favorites)) == ["ch:2.1", "ch:9.1"])
        await composer.flushSnapshot()
        let saved = await store.snapshot?.sources.first?.contributions.first { $0.shelf == .favorites }
        #expect(saved?.items.map(\.key) == ["ch:2.1", "ch:9.1"])
    }

    @Test func aSlowSourceKeepsItsSnapshotAndMarksItsShelvesUpdating() async throws {
        let store = InMemoryHomeSnapshotStore(Self.snapshot([Sample.channel("2.1", favorite: true)]))
        let slow = ScriptedSource(id: Sample.antenna, kind: .hdhomerun, capabilities: [.liveTV])
        let dvr = ScriptedSource(id: Sample.plex, capabilities: [.recordings], initial: [
            ShelfContribution(shelf: .recentRecordings, items: [Sample.recording("1", inProgress: false)],
                              freshness: .now)
        ])
        let gate = TimeoutGate()
        let composer = HomeShelfComposer(sources: [slow, dvr], snapshotStore: store, sleep: gate.sleep)
        await composer.loadSnapshot()
        let refresh = Task { await composer.refresh() }
        #expect(try await eventually { Self.keys(composer.shelf(.recentRecordings)) == ["plex:1"] })
        #expect(composer.isRefreshing)
        gate.fire()
        await refresh.value

        #expect(Self.keys(composer.shelf(.favorites)) == ["ch:2.1"])
        #expect(composer.shelf(.favorites)?.isUpdating == true)
        #expect(composer.shelf(.liveChannels)?.isUpdating == true)
        #expect(composer.shelf(.recentRecordings)?.isUpdating == false)

        // The late answer still lands, and clears the updating state.
        await slow.publish(Sample.liveContributions([Sample.channel("4.1", favorite: true)]))
        #expect(try await eventually { Self.keys(composer.shelf(.favorites)) == ["ch:4.1"] })
        #expect(composer.shelf(.favorites)?.isUpdating == false)
    }

    @Test func laterBatchesKeepUpdatingHome() async throws {
        let device = FixtureLineupProvider(try LineupFixture.antennaA())
        let source = HDHomeRunSource(lineupSource: "Antenna",
                                     devices: [device, FixtureLineupProvider(try LineupFixture.antennaB())],
                                     broker: FakeTuner().makeBroker())
        let local = LocalHomeState(favorites: [Sample.channel("13.1").id, Sample.channel("4.1").id])
        let composer = HomeShelfComposer(sources: [source], localState: local, sleep: TimeoutGate().sleep)
        await composer.refresh()
        #expect(Self.keys(composer.shelf(.favorites)) == ["ch:2.1", "ch:4.1", "ch:9.1", "ch:20.4", "ch:13.1"])
        #expect(composer.shelf(.liveChannels)?.items.count == 7)

        var changed = try LineupFixture.antennaA()
        changed.channels.removeAll { $0.guideNumber == "2.1" }
        device.script([.success(changed)])
        try await source.refresh(force: true)
        #expect(try await eventually { composer.shelf(.favorites)?.items.first?.key == "ch:4.1" })
    }

    @Test func removingASourceRemovesItsCards() async {
        let live = ScriptedSource(id: Sample.antenna, kind: .hdhomerun, capabilities: [.liveTV],
                                  initial: Sample.liveContributions([Sample.channel("2.1", favorite: true)]))
        let composer = HomeShelfComposer(sources: [live], sleep: TimeoutGate().sleep)
        await composer.refresh()
        #expect(composer.shelf(.favorites)?.items.count == 1)
        composer.setSources([])
        #expect(composer.shelf(.favorites)?.items.isEmpty == true)
        #expect(composer.shelf(.favorites)?.emptyMessage == "No Live TV source configured")
    }

    @Test func aRebuiltSourceUnderTheSameIDIsFollowed() async throws {
        let old = ScriptedSource(id: Sample.antenna, kind: .hdhomerun, capabilities: [.liveTV],
                                 initial: Sample.liveContributions([Sample.channel("2.1", favorite: true)]))
        let composer = HomeShelfComposer(sources: [old], sleep: TimeoutGate().sleep)
        await composer.refresh()
        #expect(Self.keys(composer.shelf(.favorites)) == ["ch:2.1"])

        // The registry rebuilds the source after a device was added: same ID, new instance.
        let rebuilt = ScriptedSource(id: Sample.antenna, kind: .hdhomerun, capabilities: [.liveTV])
        composer.setSources([rebuilt])
        #expect(Self.keys(composer.shelf(.favorites)) == ["ch:2.1"])  // the old cards stay until it answers
        await old.publish(Sample.liveContributions([Sample.channel("4.1", favorite: true)]))
        await rebuilt.publish(Sample.liveContributions([Sample.channel("9.1", favorite: true)]))
        #expect(try await eventually { Self.keys(composer.shelf(.favorites)) == ["ch:9.1"] })
        #expect(await rebuilt.subscriptions == 1)
        // The replaced instance is no longer heard.
        await old.publish(Sample.liveContributions([Sample.channel("5.1", favorite: true)]))
        try await Task.sleep(for: .milliseconds(50))
        #expect(Self.keys(composer.shelf(.favorites)) == ["ch:9.1"])

        // After stop(), a rebuilt source is followed from the next refresh only.
        composer.stop()
        let later = ScriptedSource(id: Sample.antenna, kind: .hdhomerun, capabilities: [.liveTV],
                                   initial: Sample.liveContributions([Sample.channel("20.1", favorite: true)]))
        composer.setSources([later])
        #expect(await later.subscriptions == 0)
        await composer.refresh()
        #expect(Self.keys(composer.shelf(.favorites)) == ["ch:20.1"])
    }

    @Test func localFavoritesNoShelfCarriesAreLookedUp() async throws {
        let movie = Sample.movie("42")
        let plex = ScriptedSource(id: Sample.plex, capabilities: [.recordings], initial: [
            ShelfContribution(shelf: .recentRecordings, items: [Sample.recording("1", inProgress: false)],
                              freshness: .now)
        ], lookupItems: [movie])
        let local = LocalHomeState(favorites: [movie.id, MediaItemID(source: Sample.plex, key: "plex:gone")])
        let composer = HomeShelfComposer(sources: [plex], localState: local, sleep: TimeoutGate().sleep)
        await composer.refresh()
        #expect(try await eventually { Self.keys(composer.shelf(.favorites)) == ["plex:42"] })
        #expect(await plex.lookups == [movie.id, MediaItemID(source: Sample.plex, key: "plex:gone")])
    }

    @Test func settingsChangesReorderAtOnce() async {
        let composer = HomeShelfComposer(sleep: TimeoutGate().sleep)
        composer.configuration = HomeShelfConfiguration(shelves: [
            HomeShelfSetting(kind: .recentRecordings), HomeShelfSetting(kind: .favorites, isEnabled: false)
        ])
        #expect(composer.shelves.map(\.kind) == [.recentRecordings])
    }

    @Test func theSnapshotHoldsNoSecrets() async throws {
        let leaky = URL(string: "https://viewer:pa55word@img.example.com/thumb.jpg?X-Plex-Token=SECRET")!
        let clean = URL(string: "https://img.example.com/poster.jpg")!
        var recording = Sample.recording("1", inProgress: false)
        recording.artwork = Artwork(poster: .remote(clean, headerKeys: ["X-Plex-Token"]),
                                    thumb: .remote(leaky, headerKeys: []))
        let store = InMemoryHomeSnapshotStore()
        let plex = ScriptedSource(id: Sample.plex, capabilities: [.recordings], initial: [
            ShelfContribution(shelf: .recentRecordings, items: [recording], freshness: .now)
        ])
        let composer = HomeShelfComposer(sources: [plex], snapshotStore: store, sleep: TimeoutGate().sleep)
        await composer.refresh()
        await composer.flushSnapshot()
        // Home itself still shows the artwork; only the cached copy drops it.
        #expect(composer.shelf(.recentRecordings)?.items.first?.artwork.thumb != nil)

        let snapshot = try #require(await store.snapshot)
        let json = try #require(String(bytes: JSONEncoder().encode(snapshot), encoding: .utf8))
        for secret in ["SECRET", "pa55word", "viewer"] { #expect(!json.contains(secret)) }
        let cached = snapshot.sources.first?.contributions.first?.items.first
        #expect(cached?.artwork.thumb == nil)
        #expect(cached?.artwork.poster == .remote(clean, headerKeys: ["X-Plex-Token"]))
    }

    @Test func theFileStoreRoundTripsAndToleratesPurges() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MediaSourceKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileHomeSnapshotStore(fileURL: directory.appending(path: "home.json"))
        #expect(await store.loadSnapshot() == nil)
        let snapshot = Self.snapshot([Sample.channel("2.1", favorite: true)])
        await store.saveSnapshot(snapshot)
        #expect(await store.loadSnapshot() == snapshot)
        try Data("not json".utf8).write(to: store.fileURL)
        #expect(await store.loadSnapshot() == nil)
    }
}
