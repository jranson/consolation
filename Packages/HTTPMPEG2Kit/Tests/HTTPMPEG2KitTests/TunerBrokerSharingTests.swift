import Foundation
import Testing
@testable import HTTPMPEG2Kit

/// Reference-counted upstreams: one tuner per channel however many subscribers share it, the last one out closes
/// it, and relay-only upstreams make way for this device's own player. No request leaves the process.
@Suite("TunerBroker sharing", .timeLimit(.minutes(1)))
struct TunerBrokerSharingTests {
    static let news = ChannelKey(source: "Antenna", guideNumber: "9.1")
    static let other = ChannelKey(source: "Antenna", guideNumber: "7.1")
    static let device = TunerDeviceID(numericValue: 0x1A2B_3C4D)

    static func request(_ channel: ChannelKey) -> TuneRequest {
        let url = URL(string: "http://192.0.2.10:5004/auto/v\(channel.guideNumber)")!
        return TuneRequest(channel: channel, routes: [DeviceChannelRef(deviceID: device, url: url)])
    }

    /// `status.json` with `free` free tuners and one tuner held by another client.
    static func status(free: Int) -> TunerBroker.StatusFetcher {
        let statuses = (0..<free).map { TunerStatus(resource: "tuner\($0)") }
            + [TunerStatus(resource: "tuner\(free)", vctNumber: "2.1", targetIP: "192.0.2.44")]
        return { _ in statuses }
    }

    static func broker(_ device: FakeTunerDevice, silence: Duration = .seconds(3),
                       fetchStatus: TunerBroker.StatusFetcher? = nil) -> TunerBroker {
        let configuration = TunerBrokerConfiguration(busyRetryDelay: .milliseconds(20), busyRetryWindow: .seconds(5),
                                                     attachMaxSilence: silence)
        return TunerBroker(configuration: configuration, makeStream: device.factory, fetchStatus: fetchStatus)
    }

    static func drain(_ subscription: ChannelSubscription) async throws -> Data {
        var data = Data()
        for try await chunk in subscription.chunks {
            if case .data(let bytes) = chunk { data.append(bytes) }
        }
        return data
    }

    @Test func twoSubscribersShareOneUpstream() async throws {
        let device = FakeTunerDevice()
        let broker = Self.broker(device)
        let player = try await broker.subscribe(Self.request(Self.news))
        let relay = try await broker.attach(to: Self.news)
        #expect(device.requests.count == 1)
        #expect(await broker.subscriberCount(for: Self.news) == 2)
        #expect(relay.route == player.route)

        let upstream = try #require(device.streams.first)
        upstream.send(Data([0x47, 1]))
        upstream.send(Data([0x47, 2]))
        upstream.end()
        #expect(try await Self.drain(player) == Data([0x47, 1, 0x47, 2]))
        #expect(try await Self.drain(relay) == Data([0x47, 1, 0x47, 2]))
    }

    @Test func theLastSubscriberToLeaveClosesTheUpstream() async throws {
        let device = FakeTunerDevice()
        let broker = Self.broker(device)
        var events = broker.events.makeAsyncIterator()
        let player = try await broker.subscribe(Self.request(Self.news))
        let relay = try await broker.attach(to: Self.news)
        #expect(await events.next() == .opened(player.route))
        player.cancel()
        #expect(device.held == 1)
        #expect(!relay.isEnded)
        #expect(await broker.currentRoute == relay.route)
        relay.cancel()
        #expect(device.held == 0)
        #expect(await events.next() == .closed(relay.route, .cancelled))
        #expect(await broker.openRoutes.isEmpty)
    }

    @Test func aReconnectJoinsTheUpstreamThatRelayClientsKeepOpen() async throws {
        let device = FakeTunerDevice()
        let broker = Self.broker(device)
        let player = try await broker.subscribe(Self.request(Self.news))
        let relay = try await broker.attach(to: Self.news)
        let again = try await broker.subscribe(Self.request(Self.news))
        #expect(device.requests.count == 1)
        #expect(player.isEnded)
        #expect(!relay.isEnded)
        #expect(!again.isEnded)
        #expect(await broker.subscriberCount(for: Self.news) == 2)
    }

    @Test func aStalledUpstreamIsReplacedNotJoined() async throws {
        let device = FakeTunerDevice()
        let broker = Self.broker(device, silence: .milliseconds(50))
        _ = try await broker.subscribe(Self.request(Self.news))
        let relay = try await broker.attach(to: Self.news)
        try await Task.sleep(for: .milliseconds(150))
        await #expect(throws: HDHomeRunClientError.unknownChannel) { _ = try await broker.attach(to: Self.news) }
        _ = try await broker.subscribe(Self.request(Self.news))
        #expect(device.requests.count == 2)
        #expect(relay.isEnded)
        #expect(device.heldAtRequest == [0, 0])
        #expect(device.maxHeld == 1)
    }

    @Test func switchingKeepsARelayOnlyUpstreamWhenATunerIsFree() async throws {
        let device = FakeTunerDevice()
        let broker = Self.broker(device, fetchStatus: Self.status(free: 1))
        let player = try await broker.subscribe(Self.request(Self.news))
        let relay = try await broker.attach(to: Self.news)
        let next = try await broker.subscribe(Self.request(Self.other))
        #expect(player.isEnded)
        #expect(!relay.isEnded)
        #expect(!next.isEnded)
        #expect(device.held == 2)
        #expect(await broker.openRoutes.map(\.channel) == [Self.other, Self.news])
        #expect(await broker.currentRoute == next.route)
    }

    @Test func switchingEndsRelayClientsWhenNoTunerIsFree() async throws {
        let device = FakeTunerDevice()
        let broker = Self.broker(device, fetchStatus: Self.status(free: 0))
        _ = try await broker.subscribe(Self.request(Self.news))
        let relay = try await broker.attach(to: Self.news)
        _ = try await broker.subscribe(Self.request(Self.other))
        #expect(relay.isEnded)
        #expect(device.heldAtRequest == [0, 0])
        #expect(device.maxHeld == 1)
        await #expect(throws: HDHomeRunClientError.cancelled) { _ = try await Self.drain(relay) }
    }

    @Test func withoutAStatusCheckRelayClientsMakeWay() async throws {
        let device = FakeTunerDevice()
        let broker = Self.broker(device)
        _ = try await broker.subscribe(Self.request(Self.news))
        let relay = try await broker.attach(to: Self.news)
        _ = try await broker.subscribe(Self.request(Self.other))
        #expect(relay.isEnded)
        #expect(device.maxHeld == 1)
    }

    @Test func aBusyDeviceEndsRelayOnlyUpstreamsAndRetries() async throws {
        let device = FakeTunerDevice([.accept("tuner0"), .fail(.allTunersInUse), .accept("tuner1")])
        let broker = Self.broker(device, fetchStatus: Self.status(free: 1))
        _ = try await broker.subscribe(Self.request(Self.news))
        let relay = try await broker.attach(to: Self.news)
        // status.json said a tuner was free, but another client took it first.
        let next = try await broker.subscribe(Self.request(Self.other))
        #expect(relay.isEnded)
        #expect(next.route.resource == "tuner1")
        #expect(device.requests.count == 3)
        #expect(await broker.openRoutes.map(\.channel) == [Self.other])
    }

    @Test func attachingToAChannelThatIsNotOpenFails() async throws {
        let device = FakeTunerDevice()
        let broker = Self.broker(device)
        await #expect(throws: HDHomeRunClientError.unknownChannel) { _ = try await broker.attach(to: Self.news) }
        _ = try await broker.subscribe(Self.request(Self.other))
        await #expect(throws: HDHomeRunClientError.unknownChannel) { _ = try await broker.attach(to: Self.news) }
        #expect(device.requests.count == 1)
    }

    @Test func aFailingUpstreamEndsEverySubscriber() async throws {
        let device = FakeTunerDevice()
        let broker = Self.broker(device)
        let player = try await broker.subscribe(Self.request(Self.news))
        let relay = try await broker.attach(to: Self.news)
        try #require(device.streams.first).fail(.connectionLost)
        await #expect(throws: HDHomeRunClientError.connectionLost) { _ = try await Self.drain(player) }
        await #expect(throws: HDHomeRunClientError.connectionLost) { _ = try await Self.drain(relay) }
        #expect(try await eventually { await broker.openRoutes.isEmpty })
    }

    @Test func aBusyAnswerRightAfterARelayHostLetGoIsRetried() async throws {
        let device = FakeTunerDevice([.fail(.allTunersInUse), .accept("tuner3")])
        let broker = Self.broker(device)
        await broker.expectRelease()
        let subscription = try await broker.subscribe(Self.request(Self.news))
        #expect(subscription.route.resource == "tuner3")
        #expect(device.requests.count == 2)
    }

    @Test func releaseAllEndsRelayClientsToo() async throws {
        let device = FakeTunerDevice()
        let broker = Self.broker(device, fetchStatus: Self.status(free: 2))
        _ = try await broker.subscribe(Self.request(Self.news))
        let relay = try await broker.attach(to: Self.news)
        _ = try await broker.subscribe(Self.request(Self.other))
        await broker.releaseAll()
        #expect(relay.isEnded)
        #expect(device.held == 0)
        #expect(await broker.openRoutes.isEmpty)
    }
}
