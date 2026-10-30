import Foundation
import HTTPMPEG2Kit
import PlaybackKit
import Testing
@testable import MediaSourceKit

/// The descriptor-to-engine mapping: what PlaybackKit takes today, and a typed error for what it can't.
@Suite("PlaybackInputMapper", .timeLimit(.minutes(1)))
struct PlaybackInputMapperTests {
    static let hls = URL(string: "https://streams.example.com/live/master.m3u8")!
    static let mp4 = URL(string: "https://streams.example.com/vod/movie.mp4")!

    static func avPlayerInput(_ descriptor: PlaybackDescriptor) throws -> (URL, AVPlayerEngine.InputKind)? {
        guard case .avPlayer(let input) = try PlaybackInputMapper.input(for: descriptor) else { return nil }
        return (input.url, input.kind)
    }

    static func feed(_ descriptor: PlaybackDescriptor) throws -> TransportStreamFeed? {
        guard case .transportStream(let feed) = try PlaybackInputMapper.input(for: descriptor) else { return nil }
        return feed
    }

    @Test func liveTunerReadsTheOpenSubscriptionThenResubscribesForReconnects() async throws {
        let tuner = FakeTuner()
        let source = HDHomeRunSource(lineupSource: "Antenna",
                                     devices: [FixtureLineupProvider(try LineupFixture.antennaA())],
                                     broker: tuner.makeBroker())
        let descriptor = try await source.playback(
            for: MediaItemID(channel: ChannelKey(source: "Antenna", guideNumber: "4.1")), request: PlaybackRequest())
        let feed = try #require(try Self.feed(descriptor))
        #expect(feed.growth == .live)
        #expect(feed.programNumber == nil)
        #expect(feed.channel == ChannelKey(source: "Antenna", guideNumber: "4.1"))

        // First connection: the descriptor's subscription, no second GET.
        let first = feed.makeSource()
        var bytes = try await first.open().makeAsyncIterator()
        let upstream = try #require(tuner.upstreams.first)
        upstream.send(Data([0x47, 0x01]))
        let chunk = try await bytes.next()
        #expect(chunk == Data([0x47, 0x01]))
        #expect(tuner.upstreams.count == 1)

        // A reconnect subscribes again: the broker closes the old GET before it opens the new one.
        let second = feed.makeSource()
        _ = try await second.open()
        #expect(tuner.upstreams.count == 2)
        #expect(upstream.isCancelled)
        second.cancel()
        #expect(tuner.upstreams.last?.isCancelled == true)
    }

    @Test func liveTunerWithoutReconnectFailsTheSecondAttempt() async throws {
        let tuner = FakeTuner()
        let broker = tuner.makeBroker()
        let request = TuneRequest(channel: ChannelKey(source: "Antenna", guideNumber: "2.1"),
                                  routes: [DeviceChannelRef(url: URL(string: "http://192.0.2.10:5004/auto/v2.1")!)])
        let lease = TunerLease(subscription: try await broker.subscribe(request))
        let feed = try #require(try Self.feed(PlaybackDescriptor(transport: .liveTuner(lease), container: .mpegTS,
                                                                 isLive: true, start: .liveEdge)))
        _ = feed.makeSource()
        await #expect(throws: PlaybackError.self) { _ = try await feed.makeSource().open() }
        #expect(tuner.upstreams.count == 1)
        await lease.release()
        #expect(tuner.upstreams.first?.isCancelled == true)
    }

    @Test func aChannelOnASharedMultiplexNamesItsProgram() async throws {
        let tuner = FakeTuner()
        let broker = tuner.makeSharingBroker(free: [0, 1, 3])
        let route = DeviceChannelRef(url: URL(string: "http://192.0.2.10:5004/auto/v31.1")!, frequency: 605_000_000,
                                     programNumber: 3, modelNumber: "HDFX-4K")
        let request = TuneRequest(channel: ChannelKey(source: "Antenna", guideNumber: "31.1"), routes: [route],
                                  purpose: .tile, prefersMultiplex: true)
        let slot = SubscriberSlot.tile(UUID())
        let lease = TunerLease(subscription: try await broker.subscribe(request, slot: slot), broker: broker,
                               request: request, slot: slot)
        #expect(tuner.upstreams.first?.url.path == "/tuner3/ch605000000")
        #expect(lease.programNumber == 3)
        #expect(lease.reconnectSlot == slot)
        guard case .transportStream(let feed) = PlaybackInputMapper.liveInput(lease) else {
            Issue.record("Expected the TS engine")
            return
        }
        #expect(feed.programNumber == 3)
        // The engine reads each connection's program after open().
        let first = feed.makeSource()
        let firstBytes = try await first.open()
        #expect(first.programNumber == 3)
        // A reconnect subscribes again in the tile's slot and lands on the multiplex again.
        let second = feed.makeSource()
        let secondBytes = try await second.open()
        #expect(second.programNumber == 3)
        withExtendedLifetime((firstBytes, secondBytes)) {}
        #expect(tuner.upstreams.count == 2)
        await lease.release()
        #expect(tuner.upstreams.allSatisfy { $0.isCancelled })
    }

    @Test func avPlayerTakesHLSDASHAndFiles() throws {
        let hls = try #require(try Self.avPlayerInput(PlaybackDescriptor(transport: .hls(Self.hls, headers: [:]))))
        #expect(hls.0 == Self.hls)
        #expect(hls.1 == .hls)
        let dashURL = URL(string: "https://streams.example.com/vod/manifest.mpd")!
        #expect(try Self.avPlayerInput(PlaybackDescriptor(transport: .dash(dashURL)))?.1 == .dash)
        #expect(try Self.avPlayerInput(PlaybackDescriptor(transport: .http(Self.mp4, headers: [:]),
                                                          container: .mp4))?.1 == .file)
        let local = URL(fileURLWithPath: "/tmp/movie.mov")
        #expect(try Self.avPlayerInput(PlaybackDescriptor(transport: .file(local), container: .mov))?.1 == .file)
        // No hint: the URL decides, and unknown URLs get a try in AVPlayer, as Quick Play does today.
        #expect(try Self.avPlayerInput(PlaybackDescriptor(transport: .http(Self.hls, headers: [:])))?.1 == .hls)
        let opaque = URL(string: "https://streams.example.com/play/abc")!
        #expect(try Self.avPlayerInput(PlaybackDescriptor(transport: .http(opaque, headers: [:])))?.1 == .file)
    }

    @Test func liveTransportStreamURLsUseOneGET() throws {
        let local = URL(string: "http://tuner.local:5004/auto/v9.1")!
        let localFeed = try #require(try Self.feed(PlaybackDescriptor(transport: .http(local, headers: [:]),
                                                                      isLive: true, start: .liveEdge)))
        #expect(localFeed.makeSource() is HTTPByteSource)
        #expect(localFeed.channel == nil)
        let remote = URL(string: "http://streams.example.com/live/stream.ts")!
        let remoteFeed = try #require(try Self.feed(PlaybackDescriptor(transport: .http(remote, headers: [:]),
                                                                       container: .mpegTS, isLive: true)))
        #expect(remoteFeed.makeSource() is RawHTTPByteSource)
    }

    @Test func requestHeadersReachBothEngines() throws {
        let token = ["X-Plex-Token": "secret"]
        let input = try PlaybackInputMapper.input(for: PlaybackDescriptor(transport: .http(Self.mp4, headers: token),
                                                                          container: .mp4))
        guard case .avPlayer(let avInput) = input else { Issue.record("not AVPlayer"); return }
        #expect(avInput.kind == .file)
        #expect(avInput.headers == token)
        let lan = URL(string: "http://192.168.1.20:32400/library/parts/1/2/file.ts")!
        let feed = try #require(try Self.feed(PlaybackDescriptor(transport: .http(lan, headers: token))))
        #expect(feed.makeSource() is HTTPByteSource)
    }

    @Test func recordedTransportStreamsPlayToTheirEnd() throws {
        let remote = URL(string: "http://streams.example.com/rec.ts")!
        let remoteFeed = try #require(try Self.feed(PlaybackDescriptor(transport: .http(remote, headers: [:]))))
        #expect(remoteFeed.growth == .complete)
        #expect(remoteFeed.makeSource() is RawHTTPByteSource)
        let file = try #require(try Self.feed(PlaybackDescriptor(transport: .file(URL(fileURLWithPath: "/tmp/a.ts")))))
        #expect(file.growth == .complete)
        #expect(file.makeSource() is FileByteSource)
    }

    @Test func growingHLSPlaysFromTheBeginningInAVPlayer() throws {
        let growing = PlaybackDescriptor(transport: .hls(Self.hls, headers: [:]), isGrowing: true, start: .beginning)
        guard case .avPlayer(let input) = try PlaybackInputMapper.input(for: growing) else {
            Issue.record("not AVPlayer")
            return
        }
        #expect(input.startsAtBeginning)
        #expect(input.configured(AVPlayerEngine.Configuration()).startsAtBeginning)
        let goLive = PlaybackDescriptor(transport: .hls(Self.hls, headers: [:]), isGrowing: true, start: .liveEdge)
        guard case .avPlayer(let live) = try PlaybackInputMapper.input(for: goLive) else { return }
        #expect(!live.startsAtBeginning)
    }

    @Test func whatTheEnginesCantTakeIsATypedError() {
        let token = ["Authorization": "Bearer secret"]
        let plainRemote = URL(string: "http://streams.example.com/vod/movie.mp4")!
        let cases: [(PlaybackDescriptor, PlaybackMappingError)] = [
            (PlaybackDescriptor(transport: .http(plainRemote, headers: token)), .insecureRequestHeaders),
            (PlaybackDescriptor(transport: .hls(URL(string: "http://streams.example.com/a.m3u8")!, headers: token)),
             .insecureRequestHeaders),
            (PlaybackDescriptor(transport: .bytes(EmptyRange())), .byteRangeSource),
            (PlaybackDescriptor(transport: .http(Self.mp4, headers: [:]), isGrowing: true), .growingFile),
            (PlaybackDescriptor(transport: .http(Self.mp4, headers: [:]), container: .mkv), .container(.mkv)),
            (PlaybackDescriptor(transport: .hls(Self.hls, headers: [:]), start: .resume(.seconds(60))),
             .startPosition(.resume(.seconds(60))))
        ]
        for (descriptor, expected) in cases {
            #expect(throws: expected) { _ = try PlaybackInputMapper.input(for: descriptor) }
        }
        let error = PlaybackMappingError.growingFile.playbackError
        #expect(error.kind == .unsupportedFormat)
        #expect(error.title == "Recordings in progress can't be played yet.")
    }

    @Test func descriptorsRedactURLsAndHeaderValues() {
        let url = URL(string: "https://user:pw@streams.example.com/path/secret-path?token=abc")!
        let descriptor = PlaybackDescriptor(transport: .http(url, headers: ["X-Plex-Token": "abc"]))
        let text = descriptor.description
        #expect(text.contains("https://streams.example.com/…"))
        #expect(text.contains("X-Plex-Token"))
        for secret in ["abc", "pw", "secret-path", "user"] { #expect(!text.contains(secret)) }
    }

    @Test func dumpAndReflectionRedactToo() {
        let url = URL(string: "https://user:pw@streams.example.com/path/secret-path?token=zzQUERYzz")!
        let descriptors = [
            PlaybackDescriptor(transport: .http(url, headers: ["X-Plex-Token": "zzSECRETzz"]), container: .mp4),
            PlaybackDescriptor(transport: .hls(url, headers: ["Authorization": "Bearer zzSECRETzz"]))
        ]
        for descriptor in descriptors {
            var dumped = ""
            dump(descriptor, to: &dumped)
            let texts = [dumped, String(reflecting: descriptor), String(reflecting: descriptor.transport),
                         String(describing: Mirror(reflecting: descriptor).children.map(\.value))]
            for text in texts {
                #expect(text.contains("streams.example.com"))
                for secret in ["zzSECRETzz", "zzQUERYzz", "secret-path", "pw@", "user"] {
                    #expect(!text.contains(secret), "\(secret) leaked")
                }
            }
            #expect(dumped.contains("X-Plex-Token") || dumped.contains("Authorization"))
        }
    }

    @MainActor
    @Test func inputsBuildTheMatchingEngine() throws {
        let hls = try PlaybackInputMapper.input(for: PlaybackDescriptor(transport: .hls(Self.hls, headers: [:])))
        let avPlayer = hls.makeEngine()
        #expect(avPlayer is AVPlayerEngine)
        #expect(avPlayer.state == .idle)
        let local = URL(string: "http://tuner.local:5004/auto/v9.1")!
        let live = try PlaybackInputMapper.input(for: PlaybackDescriptor(transport: .http(local, headers: [:]),
                                                                         isLive: true))
        let engine = live.makeEngine(timeShift: TimeShiftConfiguration(storage: .memory, capacityBytes: 1 << 20))
        #expect(engine is TransportStreamEngine)
        #expect(engine.state == .idle)
    }
}

/// A `ByteRangeSource` with nothing in it.
private struct EmptyRange: ByteRangeSource {
    func length() async throws -> UInt64 { 0 }
    func read(offset: UInt64, maxLength: Int) async throws -> Data { Data() }
}
