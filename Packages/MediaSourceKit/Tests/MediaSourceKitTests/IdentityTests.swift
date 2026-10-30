import Foundation
import HTTPMPEG2Kit
import Testing
@testable import MediaSourceKit

/// Identity formats: source IDs, item keys and card IDs never hold a DeviceID, host or IP address, and live channel
/// items map 1:1 to `ChannelKey`.
@Suite("Identity")
struct IdentityTests {
    @Test func hdhomerunLiveSourceIsOnePerLineupSource() {
        let antenna = SourceID.hdhomerunLive(lineupSource: "Antenna")
        #expect(antenna.raw == "hdhr-live:Antenna")
        #expect(antenna.hdhomerunLineupSource == "Antenna")
        #expect(SourceID.hdhomerunLive(lineupSource: "Cable") != antenna)
        #expect(SourceID(raw: "plex:abc").hdhomerunLineupSource == nil)
        #expect(SourceID.quickPlay.raw == "quickplay")
    }

    @Test func channelItemsMapOneToOneToChannelKeys() throws {
        let key = try #require(ChannelKey(stringValue: "tvch:Antenna:9.1"))
        let item = MediaItemID(channel: key)
        #expect(item.source.raw == "hdhr-live:Antenna")
        #expect(item.key == "ch:9.1")
        #expect(item.channelKey == key)
        #expect(MediaItemID(source: .quickPlay, key: "url:00").channelKey == nil)
        #expect(MediaItemID(source: .hdhomerunLive(lineupSource: "Antenna"), key: "ch:").channelKey == nil)
    }

    @Test func cardIDIsSourceThenKey() {
        let item = MediaItemID(channel: ChannelKey(source: "Antenna", guideNumber: "7.1"))
        #expect(item.cardID == "hdhr-live:Antenna:ch:7.1")
        #expect(item.description == item.cardID)
        let plex = MediaItemID(source: SourceID(raw: "plex:0f0e"), key: "plex:123")
        #expect(plex.cardID == "plex:0f0e:plex:123")
    }

    @Test func identitiesEncodeAsPlainStrings() throws {
        let item = MediaItemID(channel: ChannelKey(source: "Antenna", guideNumber: "4.1"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try #require(String(data: encoder.encode(item), encoding: .utf8))
        #expect(json == #"{"key":"ch:4.1","source":"hdhr-live:Antenna"}"#)
        #expect(try JSONDecoder().decode(MediaItemID.self, from: Data(json.utf8)) == item)
    }

    @Test func mediaItemsRoundTripThroughCodable() throws {
        let id = MediaItemID(source: SourceID(raw: "plex:0f0e"), key: "plex:42")
        let item = MediaItem(
            id: id, kind: .episode(series: "Show", season: 2, episode: 7, airDate: Date(timeIntervalSince1970: 0)),
            title: "Episode", artwork: Artwork(poster: .remote(URL(string: "http://192.0.2.20/p.jpg")!,
                                                               headerKeys: ["X-Plex-Token"]),
                                               thumb: .generatedFrame(id, position: .seconds(90))),
            duration: .seconds(1_800),
            progress: PlaybackProgress(position: .seconds(900), duration: .seconds(1_800),
                                       updatedAt: Date(timeIntervalSince1970: 100)),
            providerIDs: ["tmdb": "1"], technical: CodecHints(container: .mpegTS, video: .mpeg2, audio: .ac3))
        let decoded = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(item))
        #expect(decoded == item)
        #expect(decoded.progress?.fraction == 0.5)
        #expect(decoded.artwork.bestLandscape == item.artwork.thumb)
    }

    @Test func shelfKindsHaveStableIDsThatRoundTrip() throws {
        #expect(HomeShelfKind.builtIn.map(\.stableID) == [
            "favorites", "liveChannels", "recordingNow", "recentRecordings", "continueWatching", "quickPlayHistory"
        ])
        let library = HomeShelfKind.library(SourceID(raw: "plex:0f0e"), sectionKey: "1:tv%")
        #expect(library.stableID == "library:plex%3A0f0e:1%3Atv%25")
        // A folder source with a single root has no section key.
        let root = HomeShelfKind.library(SourceID(raw: "folder:1"), sectionKey: "")
        #expect(root.stableID == "library:folder%3A1:")
        for kind in HomeShelfKind.builtIn + [library, root] {
            #expect(HomeShelfKind(stableID: kind.stableID) == kind)
            #expect(try JSONDecoder().decode(HomeShelfKind.self, from: JSONEncoder().encode(kind)) == kind)
        }
        #expect(HomeShelfKind(stableID: "library:plex") == nil)
        #expect(HomeShelfKind(stableID: "library::1") == nil)
        #expect(HomeShelfKind(stableID: "unknown") == nil)
    }

    @Test func progressFractionIsClampedAndNeedsADuration() {
        let now = Date()
        #expect(PlaybackProgress(position: .seconds(10), updatedAt: now).fraction == nil)
        #expect(PlaybackProgress(position: .seconds(30), duration: .seconds(20), updatedAt: now).fraction == 1)
        #expect(PlaybackProgress(position: .seconds(5), duration: .zero, updatedAt: now).fraction == nil)
    }

    @Test func pagesSliceAndPointToTheNextPage() {
        let first = Page(slicing: Array(1...5), with: PageRequest(offset: 0, limit: 2))
        #expect(first.items == [1, 2])
        #expect(first.total == 5)
        #expect(first.next == PageRequest(offset: 2, limit: 2))
        let last = Page(slicing: Array(1...5), with: PageRequest(offset: 4, limit: 2))
        #expect(last.items == [5])
        #expect(last.next == nil)
        #expect(Page(slicing: Array(1...5), with: PageRequest(offset: 9, limit: 2)).items.isEmpty)
        #expect(Page(slicing: Array(1...5), with: .all).items.count == 5)
        // A page that can't advance points nowhere, so a pager never loops.
        let stuck = Page(slicing: Array(1...5), with: PageRequest(offset: 1, limit: 0))
        #expect(stuck.items.isEmpty)
        #expect(stuck.next == nil)
        #expect(stuck.total == 5)
    }
}
