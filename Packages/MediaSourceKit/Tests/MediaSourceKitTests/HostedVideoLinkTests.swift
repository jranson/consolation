import Foundation
import Testing
@testable import MediaSourceKit

/// Recognizing links to hosted videos (YouTube) that play in the service's own embed, and Bullpen bookmarks to them.
@Suite("Hosted video links")
struct HostedVideoLinkTests {
    static let videoID = "aBcDeFgHi_-"

    static func link(_ text: String) -> HostedVideoLink? {
        URL(string: text).flatMap(HostedVideoLink.init(url:))
    }

    @Test(arguments: [
        "https://www.youtube.com/watch?v=aBcDeFgHi_-",
        "https://youtube.com/watch?v=aBcDeFgHi_-&feature=share",
        "http://m.youtube.com/watch?app=desktop&v=aBcDeFgHi_-",
        "https://music.youtube.com/watch?v=aBcDeFgHi_-",
        "https://WWW.YouTube.com/watch?v=aBcDeFgHi_-",
        "https://youtu.be/aBcDeFgHi_-",
        "https://youtu.be/aBcDeFgHi_-?si=abc123",
        "https://www.youtube.com/shorts/aBcDeFgHi_-",
        "https://www.youtube.com/live/aBcDeFgHi_-?feature=shared",
        "https://www.youtube.com/embed/aBcDeFgHi_-",
        "https://www.youtube-nocookie.com/embed/aBcDeFgHi_-",
        "https://www.youtube.com/v/aBcDeFgHi_-"
    ])
    func videoLinksAreRecognized(_ text: String) throws {
        let link = try #require(Self.link(text))
        #expect(link.videoID == Self.videoID)
        #expect(link.startSeconds == nil)
        #expect(link.playlistID == nil)
    }

    @Test(arguments: [
        "https://www.youtube.com.example.net/watch?v=aBcDeFgHi_-",
        "https://notyoutube.com/watch?v=aBcDeFgHi_-",
        "https://youtube.example.com/watch?v=aBcDeFgHi_-",
        "https://youtu.be.example.org/aBcDeFgHi_-",
        "ftp://www.youtube.com/watch?v=aBcDeFgHi_-",
        "https://www.youtube.com/watch?v=short",
        "https://www.youtube.com/watch?v=aBcDeFgHi_-x",
        "https://www.youtube.com/watch?v=aBcDeFgHi%2F-",
        "https://www.youtube.com/watch",
        "https://www.youtube.com/",
        "https://www.youtube.com/@SomeChannel",
        "https://www.youtube.com/playlist?list=PL0123456789",
        "https://www.youtube.com/shorts/aBcDeFgHi_-/extra",
        "https://youtu.be/",
        "https://youtu.be/a/aBcDeFgHi_-",
        "https://media.home.example/watch?v=aBcDeFgHi_-"
    ])
    func otherLinksAreRefused(_ text: String) {
        #expect(Self.link(text) == nil)
    }

    @Test func startTimesAndPlaylistsAreRead() throws {
        #expect(Self.link("https://youtu.be/aBcDeFgHi_-?t=90")?.startSeconds == 90)
        #expect(Self.link("https://www.youtube.com/watch?v=aBcDeFgHi_-&t=1m30s")?.startSeconds == 90)
        #expect(Self.link("https://www.youtube.com/watch?v=aBcDeFgHi_-&t=1h2m3s")?.startSeconds == 3_723)
        #expect(Self.link("https://www.youtube.com/watch?v=aBcDeFgHi_-&t=45s")?.startSeconds == 45)
        #expect(Self.link("https://www.youtube.com/embed/aBcDeFgHi_-?start=12")?.startSeconds == 12)
        #expect(Self.link("https://www.youtube.com/watch?v=aBcDeFgHi_-#t=2m")?.startSeconds == 120)
        let listed = try #require(Self.link("https://www.youtube.com/watch?v=aBcDeFgHi_-&list=PLab_cd-12"))
        #expect(listed.playlistID == "PLab_cd-12")
    }

    @Test func malformedTimesStartAtTheBeginning() {
        for time in ["0", "-5", "abc", "1s2m", "1m1m", "999999", "2d", "1.5", "90000"] {
            let link = Self.link("https://www.youtube.com/watch?v=aBcDeFgHi_-&t=\(time)")
            #expect(link?.videoID == Self.videoID)
            #expect(link?.startSeconds == nil, "t=\(time)")
        }
        #expect(Self.link("https://www.youtube.com/watch?v=aBcDeFgHi_-&list=PL/../x")?.playlistID == nil)
    }

    @Test func aHostedVideoNeverReachesAnEngine() {
        let descriptor = OPDSPlayback.descriptor(for: HostedVideoLink(videoID: Self.videoID))
        #expect(throws: PlaybackMappingError.hostedVideo) { try PlaybackInputMapper.input(for: descriptor) }
        // Descriptions name no video.
        #expect(!descriptor.description.contains(Self.videoID))
    }

    // MARK: - Bookmarks in an OPDS catalog (Bullpen)

    static let bookmarks = #"""
        {"metadata":{"title":"Bookmarks"},"links":[],"publications":[
          {"metadata":{"title":"A talk","identifier":"bullpen:bm/1"},
           "links":[{"rel":"alternate","href":"https://www.youtube.com/watch?v=aBcDeFgHi_-&t=30","type":"text/html"}]},
          {"metadata":{"title":"No identifier"},
           "links":[{"rel":"http://opds-spec.org/acquisition","href":"https://youtu.be/zYxWvUtSrQp"}]},
          {"metadata":{"title":"Plays in an engine","identifier":"bullpen:bm/3"},
           "links":[{"rel":"http://opds-spec.org/acquisition","href":"/m/3.mp4","type":"video/mp4"},
                    {"rel":"related","href":"https://youtu.be/aBcDeFgHi_-"}]},
          {"metadata":{"title":"A web page","identifier":"bullpen:bm/4"},
           "links":[{"rel":"alternate","href":"https://www.example.com/watch?v=aBcDeFgHi_-","type":"text/html"}]}
        ]}
        """#

    @Test func bookmarksToHostedVideosArePlayableItems() throws {
        let feed = try JSONDecoder().decode(OPDSFeed.self, from: Data(Self.bookmarks.utf8))
        let base = BullpenFixture.base.appending(path: "opds/bookmarks.json")
        let publications = feed.publications
        #expect(publications.count == 4)
        let talk = try #require(OPDSPlayback.hostedVideo(for: publications[0], base: base))
        #expect(talk == HostedVideoLink(videoID: Self.videoID, startSeconds: 30))
        #expect(OPDSPlayback.hostedVideo(for: publications[1], base: base)?.videoID == "zYxWvUtSrQp")
        // An engine-playable version wins; a page that isn't a video is not playable.
        #expect(OPDSPlayback.choice(for: publications[2], base: base)?.container == .mp4)
        #expect(OPDSPlayback.hostedVideo(for: publications[3], base: base) == nil)

        let source = SourceID.bullpen(serverID: "test")
        let items = publications.compactMap {
            OPDSItems.item(for: $0, source: source, base: base) { _ in false }
        }
        #expect(items.map(\.title) == ["A talk", "No identifier", "Plays in an engine", "A web page"])
        #expect(items.map(\.kind) == [.clip, .clip, .clip, .folder])
        // Without an identifier, the key hashes the video, never a URL.
        #expect(items[1].id.key.hasPrefix(MediaItemID.urlKeyPrefix))
        #expect(!items[1].id.key.contains("zYxWvUtSrQp"))
    }
}
