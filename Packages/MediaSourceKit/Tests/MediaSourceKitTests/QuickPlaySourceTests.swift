import Foundation
import Testing
@testable import MediaSourceKit

/// Quick Play history as a source: URLs are hashed into IDs and never appear in an item, descriptors follow the
/// URL kind, and the Quick Play History shelf follows the history.
@Suite("QuickPlaySource")
struct QuickPlaySourceTests {
    static let tokenURL = URL(string: "https://streams.example.com/live/master.m3u8?token=s3cr3t-value")!
    static let movieURL = URL(string: "https://streams.example.com/vod/movie.mp4")!
    static let tsURL = URL(string: "http://192.0.2.10:5004/auto/v9.1")!
    static let dashURL = URL(string: "https://streams.example.com/vod/manifest.mpd")!

    static func history() -> [QuickPlayHistoryEntry] {
        [
            QuickPlayHistoryEntry(url: movieURL, lastPlayed: Date(timeIntervalSince1970: 100)),
            QuickPlayHistoryEntry(url: tokenURL, lastPlayed: Date(timeIntervalSince1970: 300)),
            QuickPlayHistoryEntry(url: tsURL, lastPlayed: Date(timeIntervalSince1970: 200)),
            QuickPlayHistoryEntry(url: movieURL, lastPlayed: Date(timeIntervalSince1970: 50))
        ]
    }

    @Test func keysAreTheSHA256OfTheURL() {
        #expect(QuickPlaySource.itemKey(for: Self.tokenURL)
                == "url:70a3365ff3310468f557a650dc18c36d653543e0e87b764d441e24323f5c1f4a")
        #expect(QuickPlaySource.itemKey(for: Self.movieURL)
                == "url:1f3af192c7377b50b450121b52f1546436d25bfb019386b7319559af92c2675d")
    }

    @Test func theURLNeverAppearsInAnItem() async throws {
        let source = QuickPlaySource(history: Self.history())
        let items = try await source.children(of: nil, page: .all).items
        #expect(items.count == 3)
        let encoded = try #require(String(bytes: JSONEncoder().encode(items), encoding: .utf8))
        for item in items {
            #expect(!item.cardID.contains("streams.example.com"))
            #expect(item.cardID.hasPrefix("quickplay:url:"))
        }
        #expect(!encoded.contains("s3cr3t"))
        #expect(!encoded.contains("token="))
        #expect(!encoded.contains("/live/"))
        let first = try #require(items.first)
        #expect(first.title == "master.m3u8")
        #expect(first.subtitle == "streams.example.com")
    }

    @Test func tokenLikePathComponentsNeverBecomeTitles() async throws {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.c2lnbmF0dXJl"
        let hex = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
        let base64 = "Zm9vYmFyQmF6UXV4MTIzNDU2Nzg5MA"
        let uuid = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
        let tokens = [jwt, "\(hex).m3u8", base64, "\(uuid).mp4", "live_\(base64)"]
        for token in tokens {
            #expect(QuickPlayTitle.isTokenLike(token), "\(token) looks like a token")
            let url = try #require(URL(string: "https://cdn.example.com/hls/\(token)"))
            #expect(QuickPlayTitle.title(for: url) == ("cdn.example.com", true))
            let item = try await QuickPlaySource(history: [QuickPlayHistoryEntry(url: url, lastPlayed: .now)])
                .children(of: nil, page: .all).items.first
            #expect(item?.title == "cdn.example.com")
            #expect(item?.subtitle == nil)
        }
        for name in ["master.m3u8", "movie.mp4", "BigBuckBunny_1080p.mp4", "tears_of_steel_1080p.mov",
                     "index.m3u8", "v9.1", "2026-10-12_news.ts", "Episode 12 - The Long Goodbye.mkv"] {
            #expect(!QuickPlayTitle.isTokenLike(name), "\(name) is a name")
        }
        let noHost = try #require(URL(string: "file:///\(hex)"))
        #expect(QuickPlayTitle.title(for: noHost).title == "Video")
        let root = try #require(URL(string: "https://streams.example.com/"))
        #expect(QuickPlayTitle.title(for: root) == ("streams.example.com", true))
    }

    @Test func historyIsNewestFirstWithOneItemPerURL() async throws {
        let source = QuickPlaySource(history: Self.history())
        let ids = try await source.children(of: nil, page: .all).items.map(\.id)
        #expect(ids == [source.itemID(for: Self.tokenURL), source.itemID(for: Self.tsURL),
                        source.itemID(for: Self.movieURL)])
        let movie = try await source.item(source.itemID(for: Self.movieURL))
        #expect(movie.addedAt == Date(timeIntervalSince1970: 100))
    }

    @Test func descriptorsFollowTheURLKind() async throws {
        let source = QuickPlaySource(history: Self.history() + [
            QuickPlayHistoryEntry(url: Self.dashURL, lastPlayed: Date(timeIntervalSince1970: 10))
        ])
        let hls = try await source.playback(for: source.itemID(for: Self.tokenURL), request: PlaybackRequest())
        guard case .hls(let hlsURL, let headers) = hls.transport else {
            Issue.record("Expected HLS")
            return
        }
        #expect(hlsURL == Self.tokenURL)
        #expect(headers.isEmpty)
        #expect(hls.start == .beginning)

        let dash = try await source.playback(for: source.itemID(for: Self.dashURL), request: PlaybackRequest())
        #expect(dash.container == .dash)

        let live = try await source.playback(for: source.itemID(for: Self.tsURL), request: PlaybackRequest())
        #expect(live.isLive)
        #expect(live.container == .mpegTS)
        #expect(live.start == .liveEdge)

        let movie = try await source.playback(for: source.itemID(for: Self.movieURL),
                                              request: PlaybackRequest(start: .resume(.seconds(30))))
        #expect(movie.container == .mp4)
        #expect(movie.start == .resume(.seconds(30)))
        #expect(!movie.isLive)
    }

    @Test func unknownItemsAreRejected() async {
        let source = QuickPlaySource(history: Self.history())
        let missing = MediaItemID(source: .quickPlay, key: "url:00")
        await #expect(throws: MediaSourceError.notFound(missing)) { _ = try await source.item(missing) }
        let foreign = MediaItemID(source: SourceID(raw: "plex:1"), key: QuickPlaySource.itemKey(for: Self.movieURL))
        await #expect(throws: MediaSourceError.wrongSource(foreign)) {
            _ = try await source.playback(for: foreign, request: PlaybackRequest())
        }
    }

    @Test func theHistoryShelfFollowsTheHistory() async throws {
        let source = QuickPlaySource()
        var updates = await source.shelfContributions().makeAsyncIterator()
        let emptyUpdate = await updates.next()
        let empty = try #require(emptyUpdate)
        #expect(empty.map(\.shelf) == [.quickPlayHistory])
        #expect(empty.first?.items.isEmpty == true)

        await source.setHistory(Self.history())
        let filledUpdate = await updates.next()
        let filled = try #require(filledUpdate)
        #expect(filled.first?.items.count == 3)
        #expect(filled.first?.freshness == Date(timeIntervalSince1970: 300))
    }
}
