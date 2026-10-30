import Foundation
import HTTPMPEG2Kit
import Testing
@testable import MediaSourceKit

/// What the composer writes to the Home snapshot, and when: never over a snapshot it hasn't read, never an empty
/// entry for a source that hasn't answered, and only shelves that are shown.
@MainActor
@Suite("Home snapshot policy", .timeLimit(.minutes(1)))
struct HomeSnapshotPolicyTests {
    static func keys(_ shelf: HomeShelf?) -> [String] {
        shelf?.items.map(\.key) ?? []
    }

    static func snapshot(_ channels: [MediaItem]) -> HomeSnapshot {
        HomeSnapshot(sources: [SourceSnapshot(source: Sample.antenna, capabilities: [.liveTV],
                                              contributions: Sample.liveContributions(channels))])
    }

    static func json(_ store: InMemoryHomeSnapshotStore) async throws -> String {
        let snapshot = try #require(await store.snapshot)
        return try #require(String(bytes: JSONEncoder().encode(snapshot), encoding: .utf8))
    }

    static func cachedFavorites(_ store: InMemoryHomeSnapshotStore, source: SourceID = Sample.antenna) async
        -> [String]? {
        let entry = await store.snapshot?.sources.first { $0.source == source }
        return entry?.contributions.first { $0.shelf == .favorites }?.items.map(\.key)
    }

    @Test func settingSourcesBeforeStartKeepsTheSnapshot() async throws {
        let store = InMemoryHomeSnapshotStore(Self.snapshot([Sample.channel("2.1", favorite: true)]))
        let live = ScriptedSource(id: Sample.antenna, kind: .hdhomerun, capabilities: [.liveTV])
        let composer = HomeShelfComposer(snapshotStore: store, sleep: TimeoutGate().sleep)
        // The registry finishes loading before Home's task starts the composer.
        composer.setSources([live])
        await composer.flushSnapshot()
        #expect(await Self.cachedFavorites(store) == ["ch:2.1"])
        await composer.loadSnapshot()
        #expect(Self.keys(composer.shelf(.favorites)) == ["ch:2.1"])
    }

    @Test func aRefreshBeforeTheSourcesAreKnownWritesNothing() async {
        let store = InMemoryHomeSnapshotStore(Self.snapshot([Sample.channel("2.1", favorite: true)]))
        let composer = HomeShelfComposer(snapshotStore: store, sleep: TimeoutGate().sleep)
        await composer.start()
        await composer.flushSnapshot()
        #expect(await store.saveCount == 0)
        #expect(await Self.cachedFavorites(store) == ["ch:2.1"])
    }

    @Test func aSourceThatHasNotAnsweredKeepsItsCachedEntry() async throws {
        let store = InMemoryHomeSnapshotStore(Self.snapshot([Sample.channel("2.1", favorite: true)]))
        let slow = ScriptedSource(id: Sample.antenna, kind: .hdhomerun, capabilities: [.liveTV])
        let dvr = ScriptedSource(id: Sample.plex, capabilities: [.recordings], initial: [
            ShelfContribution(shelf: .recentRecordings, items: [Sample.recording("1", inProgress: false)],
                              freshness: .now)
        ])
        let gate = TimeoutGate()
        // No loadSnapshot(): the first write reads the stored snapshot itself.
        let composer = HomeShelfComposer(sources: [slow, dvr], snapshotStore: store, sleep: gate.sleep)
        let refresh = Task { await composer.refresh() }
        #expect(try await eventually { Self.keys(composer.shelf(.recentRecordings)) == ["plex:1"] })
        gate.fire()
        await refresh.value
        await composer.flushSnapshot()
        #expect(await Self.cachedFavorites(store) == ["ch:2.1"])
        let recordings = await store.snapshot?.sources.first { $0.source == Sample.plex }?.contributions
        #expect(recordings?.first?.items.map(\.key) == ["plex:1"])
    }

    @Test func removingASourceRemovesItFromTheSnapshot() async throws {
        let store = InMemoryHomeSnapshotStore(Self.snapshot([Sample.channel("2.1", favorite: true)]))
        let live = ScriptedSource(id: Sample.antenna, kind: .hdhomerun, capabilities: [.liveTV])
        let composer = HomeShelfComposer(sources: [live], snapshotStore: store, sleep: TimeoutGate().sleep)
        await composer.loadSnapshot()
        composer.setSources([])
        await composer.flushSnapshot()
        #expect(await store.snapshot?.sources.isEmpty == true)
    }

    @Test func shelvesThatAreOffStayOutOfTheSnapshot() async throws {
        let url = try #require(URL(string: "https://private-host.example.net/live/channel-7.m3u8?token=t0k3n"))
        let quick = QuickPlaySource(history: [QuickPlayHistoryEntry(url: url, lastPlayed: .now)])
        let store = InMemoryHomeSnapshotStore()
        let composer = HomeShelfComposer(sources: [quick], snapshotStore: store, sleep: TimeoutGate().sleep)
        await composer.refresh()
        await composer.flushSnapshot()
        // Quick Play History is off by default: not on Home, and not in Caches either.
        #expect(composer.shelf(.quickPlayHistory) == nil)
        let hidden = try await Self.json(store)
        for leaked in ["private-host", "channel-7", "t0k3n"] { #expect(!hidden.contains(leaked)) }

        var shown = HomeShelfConfiguration.default
        shown.shelves = shown.shelves.map { HomeShelfSetting(kind: $0.kind) }
        composer.configuration = shown
        await composer.flushSnapshot()
        let shownJSON = try await Self.json(store)
        #expect(shownJSON.contains("channel-7"))
        #expect(!shownJSON.contains("t0k3n"))

        // Turning the shelf off again prunes it from the snapshot at once.
        composer.configuration = .default
        await composer.flushSnapshot()
        let prunedJSON = try await Self.json(store)
        #expect(!prunedJSON.contains("channel-7"))
    }

    @Test func discardedContributionsLeaveHomeAndTheSnapshot() async throws {
        let url = try #require(URL(string: "https://private-host.example.net/live/channel-7.m3u8"))
        let quick = QuickPlaySource(history: [QuickPlayHistoryEntry(url: url, lastPlayed: .now)])
        let store = InMemoryHomeSnapshotStore()
        let everything = HomeShelfConfiguration(shelves: HomeShelfKind.builtIn.map { HomeShelfSetting(kind: $0) })
        let composer = HomeShelfComposer(sources: [quick], configuration: everything, snapshotStore: store,
                                         sleep: TimeoutGate().sleep)
        await composer.refresh()
        await composer.flushSnapshot()
        #expect(composer.shelf(.quickPlayHistory)?.items.count == 1)
        let cachedJSON = try await Self.json(store)
        #expect(cachedJSON.contains("private-host"))

        // Home is hidden when the user clears the history, so no batch reaches the composer.
        composer.stop()
        await quick.setHistory([])
        composer.discardContributions(from: .quickPlay)
        await composer.flushSnapshot()
        // The shelf is on, so it stays, empty, with its placeholder.
        #expect(composer.shelf(.quickPlayHistory)?.items.isEmpty == true)
        #expect(composer.shelf(.quickPlayHistory)?.emptyMessage == "No Quick Play history yet")
        let clearedJSON = try await Self.json(store)
        #expect(!clearedJSON.contains("private-host"))
    }

    @Test func aFailedSourceSaysWhyAndKeepsItsSnapshot() async throws {
        let store = InMemoryHomeSnapshotStore(Self.snapshot([Sample.channel("2.1", favorite: true)]))
        let device = FixtureLineupProvider([.failure(.unreachable(host: "tuner.local", reason: nil))])
        let source = HDHomeRunSource(lineupSource: "Antenna", devices: [device], broker: FakeTuner().makeBroker())
        let local = LocalHomeState(favorites: [Sample.channel("13.1").id])
        // The gate never fires: the source must answer by itself, not by missing the soft timeout.
        let composer = HomeShelfComposer(sources: [source], localState: local, snapshotStore: store,
                                         sleep: TimeoutGate().sleep)
        await composer.start()
        let message = "Can't reach the HDHomeRun at tuner.local."
        #expect(composer.shelf(.favorites)?.isUpdating == false)
        #expect(composer.shelf(.favorites)?.items.isEmpty == true)
        #expect(composer.shelf(.favorites)?.emptyMessage == message)
        #expect(composer.shelf(.liveChannels)?.emptyMessage == message)
        await composer.flushSnapshot()
        #expect(await Self.cachedFavorites(store) == ["ch:2.1"])
        // Local favorites of a failed source aren't looked up one by one (each would be another load).
        try await Task.sleep(for: .milliseconds(50))
        #expect(device.fetchCount == 1)
    }
}
