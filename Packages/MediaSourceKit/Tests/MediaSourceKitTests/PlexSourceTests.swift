import Foundation
import PlaybackKit
import Testing
@testable import MediaSourceKit

/// The Plex source against synthetic fixtures modelled on a real server's responses (rewritten: a synthetic
/// machine identifier and DeviceID, example titles and paths, no tokens or addresses).
@Suite("PlexSource", .timeLimit(.minutes(1)))
struct PlexSourceTests {
    static let base = URL(string: "http://plex-server.local:32400/")!
    static let token = "zzTOKENzz"
    static let window = "?X-Plex-Container-Start=0&X-Plex-Container-Size="

    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/plex")
        else { throw LineupFixture.Missing(name: name) }
        return try Data(contentsOf: url)
    }

    static func server() throws -> FixtureFetcher {
        FixtureFetcher(documents: [
            "/identity": try data("identity"),
            "/library/sections/all": try data("sections"),
            "/library/sections/2/all" + window + "50": try data("section-all"),
            "/library/metadata/200/children": try data("show-children"),
            "/library/metadata/201/children": try data("season-children"),
            "/library/metadata/202": try data("metadata"),
            "/library/sections/2/recentlyAdded" + window + "30": try data("recently-added"),
            "/media/subscriptions": try data("subscriptions"),
            "/media/subscriptions/scheduled": try data("scheduled")
        ])
    }

    static func source(_ fetcher: FixtureFetcher, token: String? = token) -> PlexSource {
        let client = PlexClient(baseURL: base, token: token,
                                client: .init(product: "Test", version: "1", identifier: "test-install"),
                                fetcher: fetcher)
        return PlexSource(id: .plex(machineIdentifier: "0123456789abcdef0123456789abcdef01234567"), name: "Plex",
                          client: client)
    }

    @Test func addressesBecomeBaseURLs() {
        #expect(PlexClient.baseURL(from: "192.0.2.30")?.absoluteString == "http://192.0.2.30:32400/")
        #expect(PlexClient.baseURL(from: "media.local:32401")?.absoluteString == "http://media.local:32401/")
        #expect(PlexClient.baseURL(from: "https://plex.example.com/web")?.absoluteString == "https://plex.example.com/")
        #expect(PlexClient.baseURL(from: "http://user:pw@plex.example.com") == nil)
    }

    @Test func identityNamesTheServer() async throws {
        let client = PlexClient(baseURL: Self.base, token: nil,
                                client: .init(product: "Test", version: "1", identifier: "x"),
                                fetcher: try Self.server())
        let identity = try await client.identity()
        #expect(identity.machineIdentifier == "0123456789abcdef0123456789abcdef01234567")
        #expect(client.mediaHeaders.isEmpty)
    }

    @Test func sectionsShowsSeasonsAndRecordingsBrowse() async throws {
        let source = Self.source(try Self.server())
        let sections = try await source.children(of: nil, page: .all).items
        #expect(sections.map(\.title) == ["DVR Recordings", "Movies"])
        let shows = try await source.children(of: try #require(sections.first).id, page: PageRequest(limit: 50))
        #expect(shows.items.map(\.title) == ["Example News", "Example Sunday"])
        #expect(shows.total == 2)
        #expect(shows.next == nil)
        let show = try #require(shows.items.last)
        #expect(show.kind == .series)
        #expect(show.subtitle == "1947")
        let seasons = try await source.children(of: show.id, page: .all).items
        #expect(seasons.map(\.kind) == [.season(79)])
        let episodes = try await source.children(of: try #require(seasons.first).id, page: .all).items
        #expect(episodes.count == 2)
        let recording = try #require(episodes.last)
        #expect(recording.id.key == "plex:202")
        #expect(recording.title == "Example Sunday")
        #expect(recording.subtitle == "October 25")
        guard case let .recording(airedAt, _, inProgress, channel) = recording.kind else {
            Issue.record("not a recording")
            return
        }
        #expect(!inProgress)
        #expect(channel == "9.1 KDDD (NBC)")
        #expect(airedAt == OPDSDates.parse("2026-10-25"))
        #expect(recording.duration == .milliseconds(3_598_208))
        // Server artwork needs the token: the item names the header, never its value.
        let thumb = Self.base.appending(path: "library/metadata/202/thumb/1792944000")
        #expect(recording.artwork.thumb == .remote(thumb, headerKeys: [PlexClient.tokenHeader]))
    }

    @Test func theTokenNeverCrossesTheInternetInPlainHTTP() async throws {
        let remote = PlexClient(baseURL: URL(string: "http://192.0.2.30:32400/")!, token: Self.token,
                                client: .init(product: "Test", version: "1", identifier: "x"),
                                fetcher: try Self.server())
        let source = PlexSource(id: .plex(machineIdentifier: "x"), name: "Plex", client: remote)
        let descriptor = try await source.playback(for: MediaItemID(source: source.id, key: "plex:202"),
                                                   request: PlaybackRequest())
        #expect(throws: PlaybackMappingError.insecureRequestHeaders) {
            _ = try PlaybackInputMapper.input(for: descriptor)
        }
    }

    @Test func recordingsPlayDirectlyWithTheTokenInAHeader() async throws {
        let source = Self.source(try Self.server())
        let id = MediaItemID(source: source.id, key: "plex:202")
        let descriptor = try await source.playback(for: id, request: PlaybackRequest())
        guard case let .http(url, headers) = descriptor.transport else {
            Issue.record("not http")
            return
        }
        #expect(url.absoluteString == "http://plex-server.local:32400/library/parts/302/1792944000/file.ts")
        #expect(headers == [PlexClient.tokenHeader: Self.token])
        #expect(!url.absoluteString.contains(Self.token))
        #expect(descriptor.container == .mpegTS)
        #expect(!descriptor.isGrowing)
        #expect(!descriptor.description.contains(Self.token))
        guard case .transportStream(let feed) = try PlaybackInputMapper.input(for: descriptor) else {
            Issue.record("not the TS engine")
            return
        }
        #expect(feed.growth == .complete)
        #expect(feed.makeSource() is HTTPByteSource)
    }

    @Test func recentRecordingsComeFromTheDVRsSections() async throws {
        let fetcher = try Self.server()
        let source = Self.source(fetcher)
        var batch: [ShelfContribution]?
        for await contributions in await source.shelfContributions() {
            batch = contributions
            break
        }
        let recent = try #require(batch?.first { $0.shelf == .recentRecordings })
        #expect(recent.items.map(\.id.key) == ["plex:202"])
        #expect(fetcher.requests.contains("/media/subscriptions"))
        #expect(await source.status() == .ready)
    }

    @Test func grabOperationsDecodeWithTheirAiring() throws {
        let envelope = try JSONDecoder().decode(PlexClient.Envelope.self, from: Self.data("scheduled"))
        let operations = envelope.container.grabOperations
        #expect(operations.map(\.status) == ["inprogress", "scheduled"])
        let media = try #require(operations.first?.metadata?.media?.first)
        #expect(media.channelVcn == "9.1")
        #expect(media.beginsAt == 1_793_548_800)
        #expect(media.endsAt == 1_793_552_400)
        #expect(PlexSource.airDate("2026-11-01 05:00:00") == OPDSDates.parse("2026-11-01T05:00:00Z"))
    }

    @Test func aRefusedTokenAsksForSignIn() async throws {
        let source = Self.source(FixtureFetcher(documents: [:]))
        await #expect(throws: RemoteDocumentError.self) { _ = try await source.children(of: nil, page: .all) }
        // The fixture fetcher answers 404 for everything; a 401 maps to `authRequired`.
        #expect(BullpenSource.status(for: RemoteDocumentError.status(401, nil)) == .authRequired)
        #expect(await source.capabilities().contains(.requiresAuth))
        #expect(await !Self.source(FixtureFetcher(documents: [:]), token: nil).capabilities().contains(.requiresAuth))
    }
}
