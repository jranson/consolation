import Foundation
import HTTPMPEG2Kit
import PlaybackKit
import Testing
@testable import Consolation

/// URLs whose path names no container (IPTV's `/user/token/1234`) are probed before they play, and play in the
/// engine their first bytes call for. Probes are stubs; nothing connects.
@MainActor
struct StreamKindCacheTests {
    nonisolated private static let live = URL(string: "https://iptv.example.com/user/token/1234")!

    @Test func onlyURLsThatSayNothingAreProbed() {
        let cache = StreamKindCache { _ in .transportStream }
        #expect(cache.needsProbe(Self.live))
        #expect(cache.needsProbe(URL(string: "http://192.0.2.30:8080/play?id=7")!))
        for text in ["https://media.example.com/a.ts", "https://media.example.com/a.m3u8",
                     "https://media.example.com/a.mkv", "file:///Users/someone/Movies/clip", "rtsp://192.0.2.5/x"] {
            #expect(!cache.needsProbe(URL(string: text)!), "\(text)")
        }
    }

    @Test func aKindIsLearnedOnceAndUnknownBytesAreTriedAgain() async {
        let probes = ProbeCounter()
        let cache = StreamKindCache { url in
            probes.count(url)
            return url == Self.live ? .transportStream : .unknown
        }
        #expect(cache.kind(for: Self.live) == .unknown)
        await cache.learn(Self.live)
        await cache.learn(Self.live)
        #expect(cache.kind(for: Self.live) == .transportStream && !cache.needsProbe(Self.live))
        let page = URL(string: "https://example.com/watch/42")!
        await cache.learn(page)
        await cache.learn(page)
        #expect(cache.kind(for: page) == .unknown && cache.needsProbe(page))
        #expect(probes.urls == [Self.live, page, page])
        // A URL that names its container keeps it, whatever was learned.
        #expect(cache.kind(for: URL(string: "https://media.example.com/a.m3u8")!) == .hls)
    }

    @Test func playWaitsForTheProbeThenPlays() async throws {
        let (answers, answer) = AsyncStream.makeStream(of: URLKind.self)
        let cache = StreamKindCache { _ in
            for await kind in answers { return kind }
            return nil
        }
        var made: [PlayingItem] = []
        let session = PlayerSession(preferences: PlaybackPreferences(defaults: TestDefaults.make())) { item, _, _ in
            made.append(item)
            return FakeEngine()
        }
        session.streamKinds = cache
        session.play(Self.live)
        // "Opening…" while the first bytes are read: the item, and no engine yet.
        #expect(session.item == .url(Self.live) && session.engine == nil && made.isEmpty)
        answer.yield(.transportStream)
        try await Self.waitUntil { session.engine != nil }
        #expect(made == [.url(Self.live)])
        #expect(cache.kind(for: Self.live) == .transportStream)
        // Probed once: playing it again starts at once.
        session.stop()
        session.play(Self.live)
        #expect(session.engine != nil && made.count == 2)
    }

    @Test func stoppingDuringTheProbePlaysNothing() async throws {
        let (answers, answer) = AsyncStream.makeStream(of: URLKind.self)
        var made = 0
        let session = PlayerSession(preferences: PlaybackPreferences(defaults: TestDefaults.make())) { _, _, _ in
            made += 1
            return FakeEngine()
        }
        session.streamKinds = StreamKindCache { _ in
            for await kind in answers { return kind }
            return nil
        }
        session.play(Self.live)
        session.stop()
        answer.yield(.transportStream)
        try await Task.sleep(for: .milliseconds(200))
        #expect(made == 0 && session.item == nil)
    }

    @Test func extensionlessURLsPlayInTheEngineTheirBytesCallFor() async {
        var factory = EngineFactory(preferences: PlaybackPreferences(defaults: TestDefaults.make()),
                                    broker: TunerBroker())
        factory.streamKinds = StreamKindCache { url in url == Self.live ? .transportStream : .matroska }
        #expect(factory.makeEngine(for: .url(Self.live)) is AVPlayerEngine, "not probed yet")
        await factory.streamKinds.learn(Self.live)
        #expect(factory.makeEngine(for: .url(Self.live)) is TransportStreamEngine)
        let movie = URL(string: "https://media.example.com/stream/abc")!
        await factory.streamKinds.learn(movie)
        #expect(factory.makeEngine(for: .url(movie)) is MatroskaEngine)
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }
}

/// The URLs a stub probe was asked about.
nonisolated private final class ProbeCounter: @unchecked Sendable {
    // @unchecked: `asked` is only touched under `lock`.
    private let lock = NSLock()
    private var asked: [URL] = []

    func count(_ url: URL) {
        lock.withLock { asked.append(url) }
    }

    var urls: [URL] { lock.withLock { asked } }
}
