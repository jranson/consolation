import Foundation
import PlaybackKit
import Testing
@testable import MediaSourceKit

/// The Bullpen source against the shared contract fixtures.
@Suite("BullpenSource", .timeLimit(.minutes(1)))
struct BullpenSourceTests {
    @Test func addressesBecomeBaseURLs() {
        #expect(BullpenClient.baseURL(from: "media.local")?.absoluteString == "http://media.local:7992/")
        #expect(BullpenClient.baseURL(from: " 192.0.2.10:8080 ")?.absoluteString == "http://192.0.2.10:8080/")
        #expect(BullpenClient.baseURL(from: "https://tv.example.com/bullpen")?.absoluteString
            == "https://tv.example.com/bullpen/")
        #expect(BullpenClient.baseURL(from: "https://user:pw@tv.example.com/") == nil)
        #expect(BullpenClient.baseURL(from: "ftp://tv.example.com/") == nil)
        #expect(BullpenClient.baseURL(from: "") == nil)
    }

    @Test func theCatalogAndServerDocumentName() async throws {
        let client = BullpenClient(baseURL: BullpenFixture.base, fetcher: try BullpenFixture.server())
        let catalog = try await client.catalog()
        #expect(catalog.has(BullpenVocabulary.channels))
        #expect(catalog.url(BullpenVocabulary.library)?.absoluteString == "https://bullpen.home.example/opds/root.json")
        #expect(catalog.anchor?.host() == "bullpen.home.example")
        let server = try await client.server(catalog)
        #expect(server.sourceID.raw == "bullpen:01a16244-0000-7000-8000-00000000c0de")
        #expect(server.auth?.required == true)
        #expect(SourceID.bullpen(serverID: "01a1").raw == "bullpen:01a1")
    }

    @Test func theTopLevelIsLiveTVThenTheLibrarysFeeds() async throws {
        let source = BullpenFixture.source(try BullpenFixture.server())
        // Before it connects, Home already knows it is a DVR (its Recent Recordings placeholder isn't "connect one").
        #expect(await source.capabilities().contains(.recordings))
        let top = try await source.children(of: nil, page: .all).items
        #expect(top.map(\.title) == ["Live TV", "Recordings", "Recording now", "Series", "Channels", "Movies", "TV",
                                     "Videos"])
        #expect(await source.status() == .ready)
        #expect(await source.capabilities().contains([.browse, .recordings]))
        #expect(await !source.capabilities().contains(.liveTV))
    }

    @Test func liveChannelsPlayTheProxysHLS() async throws {
        let source = BullpenFixture.source(try BullpenFixture.server())
        let channels = try await source.children(of: MediaItemID(source: source.id, key: "live:"), page: .all).items
        // The hidden ATSC 3.0 channel stays out.
        #expect(channels.map(\.title) == ["KDDD-HD"])
        let channel = try #require(channels.first)
        #expect(channel.kind == .channel(number: "9.1", callSign: "KDDD", isHD: false, isFavorite: false))
        let descriptor = try await source.playback(for: channel.id, request: PlaybackRequest())
        #expect(descriptor.isLive)
        guard case .hls(let url, let headers) = descriptor.transport else {
            Issue.record("not HLS")
            return
        }
        #expect(headers.isEmpty)
        #expect(url.path().hasSuffix("/live/antenna-9-1/master.m3u8"))
    }

    @Test func aRecordingInProgressPlaysFromItsBeginning() async throws {
        let fetcher = try BullpenFixture.server()
        let source = BullpenFixture.source(fetcher)
        let feed = MediaItemID(source: source.id, key: "feed:/opds/recordings.json")
        let page = try await source.children(of: feed, page: PageRequest(limit: 50)).items
        #expect(page.map(\.title) == ["Pilot"])
        // Asking for more than the first page follows its `next` link.
        #expect(fetcher.requests.contains("/opds/recordings.json?cursor=EXAMPLE-CURSOR"))
        let descriptor = try await source.playback(for: try #require(page.first).id, request: PlaybackRequest())
        #expect(descriptor.isGrowing)
        guard case .avPlayer(let input) = try PlaybackInputMapper.input(for: descriptor) else {
            Issue.record("not AVPlayer")
            return
        }
        #expect(input.kind == .hls)
        #expect(input.startsAtBeginning)
    }

    @Test func homeGetsRecordingNowAndPinnableLibraryShelves() async throws {
        let fetcher = try BullpenFixture.server()
        let source = BullpenFixture.source(fetcher)
        let stream = await source.shelfContributions()
        var iterator = stream.makeAsyncIterator()
        let batch = try #require(await iterator.next())
        let recordingNow = try #require(batch.first { $0.shelf == .recordingNow })
        #expect(recordingNow.items.map(\.title) == ["Pilot"])
        let library = try #require(batch.first { if case .library = $0.shelf { true } else { false } })
        #expect(library.title == "Recently added")
        #expect(library.items.map(\.title) == ["Example Movie"])
        // No recent-recordings group at the root: the recordings feed is read, and its in-progress entry left out.
        #expect(batch.first { $0.shelf == .recentRecordings }?.items.isEmpty == true)
        // A card from the snapshot plays after the shelves were read.
        let item = try #require(recordingNow.items.first)
        #expect(try await source.item(item.id).title == "Pilot")
    }

    @Test func aServerThatNeedsSignInSaysSo() async throws {
        let source = BullpenFixture.source(try BullpenFixture.server(catalog: try BullpenFixture.data("api-catalog")))
        await #expect(throws: RemoteDocumentError.status(401, nil)) {
            _ = try await source.children(of: nil, page: .all)
        }
        #expect(await source.status() == .authRequired)
        #expect(await source.capabilities().contains(.requiresAuth))
    }

    @Test func problemDetailsDecodeWithTheirMessage() throws {
        let problem = try JSONDecoder().decode(ProblemDetails.self,
                                               from: BullpenFixture.data("problem-tuner-conflict"))
        #expect(problem.status == 409)
        #expect(problem.type == "https://centennialoss.org/bullpen/problems/tuner-conflict")
        #expect(problem.message == "every tuner is booked from 20:00 to 21:00")
    }

    @Test func unreachableAndRefusedServersMapToStatuses() {
        #expect(BullpenSource.status(for: RemoteDocumentError.unreachable("offline")) == .unreachable("offline"))
        #expect(BullpenSource.status(for: RemoteDocumentError.status(403, nil)) == .authRequired)
        #expect(BullpenSource.status(for: RemoteDocumentError.status(500, ProblemDetails(title: "Broken")))
            == .unreachable("Broken"))
    }
}
