import Foundation
import Testing
@testable import MediaSourceKit

/// OPDS 2.0 with the video profile, read from Bullpen's contract fixtures.
@Suite("OPDS")
struct OPDSTests {
    static let base = BullpenFixture.base.appending(path: "opds/root.json")

    static func root() throws -> OPDSFeed {
        try JSONDecoder().decode(OPDSFeed.self, from: BullpenFixture.data("opds-root"))
    }

    @Test func aFeedReadsNavigationGroupsAndProfileTerms() throws {
        let feed = try Self.root()
        #expect(feed.title == "Bullpen")
        #expect(feed.conformsTo == [OPDSVideoProfile.uri])
        #expect(feed.navigation.map(\.title) == ["Recordings", "Recording now", "Series", "Channels", "Movies", "TV",
                                                 "Videos"])
        #expect(feed.groups.map(\.title) == ["Recording now", "Recently added"])
        let recording = try #require(feed.groups.first?.publications.first)
        let metadata = recording.metadata
        #expect(metadata.kind == .episode)
        #expect(metadata.inProgress)
        #expect(metadata.season == 1)
        #expect(metadata.episode == 1)
        #expect(metadata.seriesName == "Example Show")
        #expect(metadata.channel?.label == "9.1 KDDD")
        #expect(metadata.recordedAt == OPDSDates.parse("2026-10-11T20:14:03Z"))
        #expect(metadata.published == OPDSDates.parse("2026-10-11"))
        let link = try #require(recording.links.first)
        #expect(link.mediaType == "application/vnd.apple.mpegurl")
        #expect(link.codecs == ["avc1.640028", "mp4a.40.2"])
        #expect(link.alternates.first?.mediaType == "application/dash+xml")
    }

    @Test func malformedEntriesAreDroppedNotFatal() throws {
        let json = #"""
            {"metadata":{"title":"T"},"links":[{"rel":["self","x"],"href":"/a.json"},{"rel":"next"}],
             "publications":[{"metadata":{"title":"Good"},"links":[]},{"links":[]}],
             "navigation":[{"href":"/b.json","title":7}]}
            """#
        let feed = try JSONDecoder().decode(OPDSFeed.self, from: Data(json.utf8))
        #expect(feed.links.map(\.href) == ["/a.json"])
        #expect(feed.links.first?.rels == ["self", "x"])
        #expect(feed.publications.map(\.metadata.title) == ["Good"])
        #expect(feed.navigation.first?.title == nil)
        #expect(feed.next == nil)
    }

    @Test func playbackPrefersHLSThenTheTallestThatFits() throws {
        let feed = try Self.root()
        let recording = try #require(feed.groups[0].publications.first)
        let choice = try #require(OPDSPlayback.choice(for: recording, base: Self.base))
        #expect(choice.container == .hls)
        #expect(choice.url.host() == "bullpen.home.example")
        #expect(choice.url.path().hasSuffix("/master.m3u8"))
        let descriptor = OPDSPlayback.descriptor(for: choice, metadata: recording.metadata)
        #expect(descriptor.isGrowing)
        #expect(descriptor.start == .beginning)
        let movie = try #require(feed.groups[1].publications.first)
        #expect(OPDSPlayback.choice(for: movie, base: Self.base)?.container == .mp4)
        // Too tall for the screen: the only version still plays rather than nothing.
        #expect(OPDSPlayback.choice(for: movie, base: Self.base, maxHeight: 720)?.container == .mp4)
    }

    @Test func itemsKeepToTheSourcesOriginForArtwork() throws {
        let feed = try Self.root()
        let source = SourceID.bullpen(serverID: "test")
        let recording = try #require(feed.groups[0].publications.first)
        let item = try #require(OPDSItems.item(for: recording, source: source, base: Self.base) { _ in false })
        #expect(item.id.key == "pub:urn:uuid:01a16250-1111-7000-8000-000000000042")
        #expect(item.kind == .recording(airedAt: OPDSDates.parse("2026-10-11"),
                                        recordedAt: OPDSDates.parse("2026-10-11T20:14:03Z"), inProgress: true,
                                        channel: "9.1 KDDD"))
        #expect(item.artwork == Artwork())
        let movie = try #require(feed.groups[1].publications.first)
        let movieItem = try #require(OPDSItems.item(for: movie, source: source, base: Self.base) { _ in true })
        #expect(movieItem.kind == .movie(year: 2025))
        #expect(movieItem.duration == .milliseconds(7_203_500))
        #expect(movieItem.artwork.poster == .remote(URL(string: "https://img.home.example/poster.jpg")!,
                                                    headerKeys: []))
        let folder = try #require(OPDSItems.folder(for: feed.navigation[1], source: source, base: Self.base))
        #expect(folder.id.key == "feed:/opds/recordings.json?state=recording")
        #expect(folder.kind == .folder)
    }
}
