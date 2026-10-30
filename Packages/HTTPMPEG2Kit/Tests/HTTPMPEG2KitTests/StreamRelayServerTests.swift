import Foundation
import Synchronization
import Testing
@testable import HTTPMPEG2Kit

/// The relay over loopback against a fake tuner: fan-out to several clients from one upstream, slow clients
/// dropped without holding anything up, and the protocol's error answers. Nothing is advertised over Bonjour and
/// nothing leaves the machine.
@Suite("StreamRelayServer", .serialized, .timeLimit(.minutes(1)))
struct StreamRelayServerTests {
    static let news = TunerBrokerSharingTests.news

    /// A broker playing `news` from a fake tuner, and a loopback relay serving it.
    struct Fixture {
        let device = FakeTunerDevice()
        let broker: TunerBroker
        let player: ChannelSubscription
        let server: StreamRelayServer
        let port: UInt16

        init(maxClients: Int = 4, maxQueuedBytes: Int = 1 << 20) async throws {
            broker = TunerBrokerSharingTests.broker(device)
            player = try await broker.subscribe(TunerBrokerSharingTests.request(StreamRelayServerTests.news))
            let broker = broker
            let configuration = StreamRelayServerConfiguration(
                serviceType: nil, instanceID: "test", maxClients: maxClients, maxQueuedBytes: maxQueuedBytes,
                requestTimeout: .seconds(2), loopbackOnly: true)
            server = StreamRelayServer(configuration: configuration, channels: [StreamRelayServerTests.news],
                                       attach: Self.attacher(broker))
            port = try await server.start()
        }

        static func attacher(_ broker: TunerBroker) -> StreamRelayServer.Attach {
            { channel throws(HDHomeRunClientError) in try await broker.attach(to: channel) }
        }

        var upstream: FakeTunerStream {
            get throws { try #require(device.streams.first) }
        }

        func subscribers() async -> Int {
            await broker.subscriberCount(for: StreamRelayServerTests.news)
        }
    }

    @Test func fansOneTunerOutToSeveralClients() async throws {
        let fixture = try await Fixture()
        defer { fixture.server.stop() }
        let first = RelayTestClient(port: fixture.port)
        let second = RelayTestClient(port: fixture.port)
        first.get(RelayRequest.streamPath(for: Self.news))
        second.get(RelayRequest.streamPath(for: Self.news))
        #expect(try await eventually { await fixture.subscribers() == 3 })
        #expect(fixture.server.clientCount == 2)

        let payload = Data((0..<188 * 10).map { UInt8(truncatingIfNeeded: $0) })
        try fixture.upstream.send(payload)
        #expect(try await eventually { first.body == payload && second.body == payload })
        #expect(first.head?.hasPrefix("HTTP/1.1 200 OK") == true)
        #expect(first.head?.contains("Content-Type: video/mpeg") == true)
        #expect(fixture.device.requests.count == 1)
    }

    @Test func aClientHangingUpLeavesTheOthersWatching() async throws {
        let fixture = try await Fixture()
        defer { fixture.server.stop() }
        let client = RelayTestClient(port: fixture.port)
        client.get(RelayRequest.streamPath(for: Self.news))
        #expect(try await eventually { await fixture.subscribers() == 2 })
        client.cancel()
        #expect(try await eventually { await fixture.subscribers() == 1 })
        #expect(fixture.server.clientCount == 0)
        #expect(fixture.device.held == 1)
    }

    @Test func aSlowClientIsDroppedWithoutHoldingUpTheTuner() async throws {
        let fixture = try await Fixture(maxQueuedBytes: 1 << 20)
        defer { fixture.server.stop() }
        let fast = RelayTestClient(port: fixture.port)
        let slow = RelayTestClient(port: fixture.port, reads: false)
        fast.get(RelayRequest.streamPath(for: Self.news))
        slow.get(RelayRequest.streamPath(for: Self.news))
        #expect(try await eventually { await fixture.subscribers() == 3 })

        let player = fixture.player
        let playerBytes = Task { try await TunerBrokerSharingTests.drain(player).count }
        let chunk = Data(repeating: 0x47, count: 64 * 1_024)
        let total = 384 * chunk.count
        for _ in 0..<384 {
            try fixture.upstream.send(chunk)
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(try await eventually { await fixture.subscribers() == 2 })
        #expect(try await eventually { fast.body.count == total })
        #expect(fixture.server.clientCount == 1)
        try fixture.upstream.end()
        #expect(try await playerBytes.value == total)
        #expect(try await eventually { fast.isClosed })
    }

    @Test func refusesClientsPastTheLimit() async throws {
        let fixture = try await Fixture(maxClients: 1)
        defer { fixture.server.stop() }
        let first = RelayTestClient(port: fixture.port)
        first.get(RelayRequest.streamPath(for: Self.news))
        #expect(try await eventually { fixture.server.clientCount == 1 })
        let second = RelayTestClient(port: fixture.port)
        second.get(RelayRequest.streamPath(for: Self.news))
        #expect(try await eventually { second.isClosed })
        #expect(second.head?.hasPrefix("HTTP/1.1 503") == true)
        #expect(await fixture.subscribers() == 2)
    }

    @Test func answersInfoAndErrors() async throws {
        let fixture = try await Fixture()
        defer { fixture.server.stop() }
        let info = RelayTestClient(port: fixture.port)
        info.get(RelayRequest.infoPath)
        #expect(try await eventually { info.isClosed })
        #expect(info.head?.hasPrefix("HTTP/1.1 200 OK") == true)
        #expect(try JSONDecoder().decode(RelayInfo.self, from: info.body).channels == ["tvch:Antenna:9.1"])

        let other = RelayTestClient(port: fixture.port)
        other.get(RelayRequest.streamPath(for: ChannelKey(source: "Antenna", guideNumber: "2.1")))
        #expect(try await eventually { other.isClosed })
        #expect(other.head?.hasPrefix("HTTP/1.1 404") == true)

        let post = RelayTestClient(port: fixture.port)
        post.send("POST /v1/info HTTP/1.1\r\n\r\n")
        #expect(try await eventually { post.isClosed })
        #expect(post.head?.hasPrefix("HTTP/1.1 405") == true)
        #expect(fixture.server.clientCount == 0)
        #expect(fixture.device.requests.count == 1)
    }

    @Test func stoppingEndsEveryClientButNotThePlayer() async throws {
        let fixture = try await Fixture()
        let client = RelayTestClient(port: fixture.port)
        client.get(RelayRequest.streamPath(for: Self.news))
        #expect(try await eventually { await fixture.subscribers() == 2 })
        fixture.server.stop()
        #expect(try await eventually { client.isClosed })
        #expect(try await eventually { await fixture.subscribers() == 1 })
        #expect(!fixture.player.isEnded)
    }

    @Test func theUpstreamEndingClosesTheClients() async throws {
        let fixture = try await Fixture()
        defer { fixture.server.stop() }
        let client = RelayTestClient(port: fixture.port)
        client.get(RelayRequest.streamPath(for: Self.news))
        #expect(try await eventually { await fixture.subscribers() == 2 })
        try fixture.upstream.send(Data([0x47, 0x00]))
        try fixture.upstream.end()
        #expect(try await eventually { client.isClosed })
        #expect(client.body == Data([0x47, 0x00]))
    }
}
