import Foundation
import Testing
@testable import MediaSourceKit

/// The merge rules on their own: order and switches, de-duplication, local favorites and resume points, ranks, empty
/// messages and hidden shelves.
@Suite("HomeShelfMerge")
struct HomeShelfMergeTests {
    typealias State = HomeShelfMerge.SourceState

    static func live(_ channels: [MediaItem], late: Bool = false) -> State {
        State(id: Sample.antenna, capabilities: [.liveTV], contributions: Sample.liveContributions(channels),
              resolvedItems: [], isLate: late)
    }

    static func compose(_ sources: [State], configuration: HomeShelfConfiguration = .default,
                        local: LocalHomeState = LocalHomeState()) -> [HomeShelf] {
        HomeShelfMerge.compose(sources: sources, configuration: configuration, local: local,
                               messages: HomeShelfMessages())
    }

    @Test func withNoSourcesTheShelvesSayWhatToConfigure() {
        let shelves = Self.compose([])
        #expect(shelves.map(\.kind) == [.favorites, .liveChannels, .recentRecordings])
        #expect(shelves.map(\.emptyMessage) == [
            "No Live TV source configured", "No Live TV source configured", "Connect a DVR source in Settings"
        ])
        #expect(shelves.map(\.title) == ["Favorites", "Live TV Channels", "Recent Recordings"])
        #expect(shelves.allSatisfy { $0.items.isEmpty && !$0.isUpdating })
    }

    @Test func aLiveSourceWithoutFavoritesSaysSoInstead() {
        let shelves = Self.compose([Self.live([Sample.channel("2.1")])])
        #expect(Self.compose([Self.live([Sample.channel("2.1")])]).first?.emptyMessage == "No favorite channels yet")
        #expect(shelves[1].items.count == 1)
        #expect(shelves[1].emptyMessage == nil)
    }

    @Test func unknownCapabilitiesShowNoPlaceholder() {
        let pending = State(id: Sample.plex, capabilities: nil, contributions: [], resolvedItems: [], isLate: false)
        let shelves = Self.compose([pending])
        #expect(shelves.map(\.kind) == [.favorites, .liveChannels, .recentRecordings])
        #expect(shelves.allSatisfy { $0.emptyMessage == nil })
    }

    @Test func shelvesFollowTheConfiguredOrderAndSwitches() {
        let configuration = HomeShelfConfiguration(shelves: [
            HomeShelfSetting(kind: .liveChannels),
            HomeShelfSetting(kind: .quickPlayHistory),
            HomeShelfSetting(kind: .favorites),
            HomeShelfSetting(kind: .recentRecordings, isEnabled: false),
            HomeShelfSetting(kind: .liveChannels)
        ])
        let history = State(id: .quickPlay, capabilities: [.browse], contributions: [
            ShelfContribution(shelf: .quickPlayHistory, items: [Sample.movie("q", source: .quickPlay)],
                              freshness: .now)
        ], resolvedItems: [], isLate: false)
        let shelves = Self.compose([Self.live([Sample.channel("2.1", favorite: true)]), history],
                                   configuration: configuration)
        #expect(shelves.map(\.kind) == [.liveChannels, .quickPlayHistory, .favorites])
    }

    @Test func localFavoritesJoinDeviceFavoritesOnce() {
        let channels = [Sample.channel("2.1", favorite: true), Sample.channel("4.1", favorite: true),
                        Sample.channel("9.1")]
        let local = LocalHomeState(favorites: [
            Sample.channel("4.1").id, Sample.channel("9.1").id, Sample.channel("99.9").id
        ])
        let favorites = Self.compose([Self.live(channels)], local: local)[0]
        #expect(favorites.items.map(\.key) == ["ch:2.1", "ch:4.1", "ch:9.1"])
    }

    @Test func continueWatchingComesFromLocalResumePointsNewestFirst() {
        let movies = [Sample.movie("a"), Sample.movie("b"), Sample.movie("c")]
        let plex = State(id: Sample.plex, capabilities: [.recordings], contributions: [
            ShelfContribution(shelf: .library(Sample.plex, sectionKey: "1"), items: movies, freshness: .now)
        ], resolvedItems: [], isLate: false)
        func point(_ item: MediaItem, at seconds: TimeInterval, finished: Bool = false) -> ResumePoint {
            ResumePoint(item: item.id, progress: PlaybackProgress(
                position: .seconds(60), duration: .seconds(600), updatedAt: Date(timeIntervalSince1970: seconds),
                isFinished: finished))
        }
        let local = LocalHomeState(resumePoints: [
            point(movies[0], at: 10), point(movies[1], at: 30), point(movies[2], at: 20, finished: true)
        ])
        let shelf = Self.compose([plex], local: local).first { $0.kind == .continueWatching }
        #expect(shelf?.items.map(\.key) == ["plex:b", "plex:a"])
        #expect(shelf?.items.first?.progress?.fraction == 0.1)
        #expect(Self.compose([plex]).contains { $0.kind == .continueWatching } == false)
    }

    @Test func higherRanksComeFirstAndDuplicatesCollapse() {
        let first = State(id: Sample.plex, capabilities: [.recordings], contributions: [
            ShelfContribution(shelf: .recentRecordings, items: [Sample.recording("1", inProgress: false)],
                              rank: 0, freshness: .now)
        ], resolvedItems: [], isLate: false)
        let other = SourceID(raw: "plex:other")
        let second = State(id: other, capabilities: [.recordings], contributions: [
            ShelfContribution(shelf: .recentRecordings, items: [
                Sample.recording("2", inProgress: false, source: other),
                Sample.recording("2", inProgress: false, source: other)
            ], rank: 5, freshness: .now)
        ], resolvedItems: [], isLate: false)
        let shelf = Self.compose([first, second]).first { $0.kind == .recentRecordings }
        #expect(shelf?.items.map(\.cardID) == ["plex:other:plex:2", "plex:0f0e0d0c:plex:1"])
    }

    @Test func onlyTheTransientShelvesAreHiddenWhenEmpty() {
        let library = HomeShelfKind.library(Sample.plex, sectionKey: "1")
        let configuration = HomeShelfConfiguration(shelves: [
            HomeShelfSetting(kind: .recordingNow), HomeShelfSetting(kind: .continueWatching),
            HomeShelfSetting(kind: .quickPlayHistory), HomeShelfSetting(kind: library)
        ])
        let plex = State(id: Sample.plex, capabilities: [.recordings, .inProgressRecordings], contributions: [],
                         resolvedItems: [], isLate: false)
        let empty = Self.compose([plex], configuration: configuration)
        // Recording Now and Continue Watching hide; Quick Play History and pinned libraries keep a placeholder.
        #expect(empty.map(\.kind) == [.quickPlayHistory, library])
        #expect(empty.map(\.emptyMessage) == ["No Quick Play history yet", "Nothing in this library yet"])
        #expect(empty.map(\.title) == ["Quick Play History", "Library"])

        var filled = plex
        filled.contributions = [
            ShelfContribution(shelf: .recordingNow, items: [Sample.recording("now", inProgress: true)],
                              freshness: .now),
            ShelfContribution(shelf: library, items: [Sample.movie("m")], freshness: .now, title: "Movies")
        ]
        let shelves = Self.compose([filled], configuration: configuration)
        #expect(shelves.map(\.title) == ["Recording Now", "Quick Play History", "Movies"])
        #expect(shelves.map(\.emptyMessage) == [nil, "No Quick Play history yet", nil])

        // A library whose source failed says why.
        var failed = plex
        failed.status = .authRequired
        #expect(Self.compose([failed], configuration: configuration).last?.emptyMessage
                == "Sign in again in Settings")
    }

    @Test func aFailedSourceSaysWhyItsShelvesAreEmpty() {
        func live(_ status: SourceStatus?) -> State {
            State(id: Sample.antenna, capabilities: [.liveTV], contributions: Sample.liveContributions([]),
                  resolvedItems: [], isLate: false, status: status)
        }
        let denied = Self.compose([live(.localNetworkDenied)])
        #expect(denied.first { $0.kind == .favorites }?.emptyMessage == "Local Network access is off")
        #expect(denied.first { $0.kind == .liveChannels }?.emptyMessage == "Local Network access is off")
        #expect(denied.allSatisfy { !$0.isUpdating })
        let unreachable = Self.compose([live(.unreachable("Can't reach the HDHomeRun at tuner.local."))])
        #expect(unreachable.first?.emptyMessage == "Can't reach the HDHomeRun at tuner.local.")
        #expect(Self.compose([live(.unreachable(""))]).first?.emptyMessage == "Can't reach this source right now")
        #expect(Self.compose([live(.authRequired)]).first?.emptyMessage == "Sign in again in Settings")
        // Degraded still works, and one healthy provider is enough for the usual message.
        #expect(Self.compose([live(.degraded("1 of 2 tuners didn't answer."))]).first?.emptyMessage
                == "No favorite channels yet")
        var cable = live(.ready)
        cable.id = .hdhomerunLive(lineupSource: "Cable")
        #expect(Self.compose([live(.localNetworkDenied), cable]).first?.emptyMessage == "No favorite channels yet")
        // Recent Recordings follows the DVR's status the same way.
        let dvr = State(id: Sample.plex, capabilities: [.recordings], contributions: [], resolvedItems: [],
                        isLate: false, status: .authRequired)
        #expect(Self.compose([dvr]).first { $0.kind == .recentRecordings }?.emptyMessage
                == "Sign in again in Settings")
    }

    @Test func aLateSourceMarksTheShelvesItFeeds() {
        let shelves = Self.compose([Self.live([Sample.channel("2.1", favorite: true)], late: true)])
        #expect(shelves.first { $0.kind == .favorites }?.isUpdating == true)
        #expect(shelves.first { $0.kind == .liveChannels }?.isUpdating == true)
        #expect(shelves.first { $0.kind == .recentRecordings }?.isUpdating == false)

        let unknown = State(id: Sample.plex, capabilities: nil, contributions: [], resolvedItems: [], isLate: true)
        #expect(Self.compose([unknown]).allSatisfy { $0.isUpdating })
    }
}
