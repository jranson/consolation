import Foundation
import Synchronization
import Testing
@testable import HTTPMPEG2Kit

/// `TunerBroker` against a scripted fake device: one upstream at a time, close before open, the 805 retry right after
/// our own release, failover and the free-tuner check. No request leaves the process.
@Suite("TunerBroker", .timeLimit(.minutes(1)))
struct TunerBrokerTests {
    static let channel = ChannelKey(source: "Antenna", guideNumber: "7.1")
    static let deviceA = TunerDeviceID(numericValue: 0x1A2B_3C4D)
    static let deviceB = TunerDeviceID(numericValue: 0x5E6F_7A8B)
    static let refA = DeviceChannelRef(deviceID: deviceA, url: URL(string: "http://192.0.2.10:5004/auto/v7.1")!)
    static let refB = DeviceChannelRef(deviceID: deviceB, url: URL(string: "http://192.0.2.11:5004/auto/v7.1")!)

    static func request(_ routes: [DeviceChannelRef] = [refA], purpose: TunePurpose = .watch) -> TuneRequest {
        TuneRequest(channel: channel, routes: routes, purpose: purpose)
    }

    static func broker(_ device: FakeTunerDevice, delay: Duration = .milliseconds(20),
                       fetchStatus: TunerBroker.StatusFetcher? = nil) -> TunerBroker {
        TunerBroker(configuration: TunerBrokerConfiguration(busyRetryDelay: delay, busyRetryWindow: .seconds(5)),
                    makeStream: device.factory, fetchStatus: fetchStatus)
    }

    /// Polls until `condition` holds or about two seconds pass.
    static func eventually(_ condition: () async -> Bool) async throws -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    @Test func subscriptionCarriesTheRouteAndTheBytes() async throws {
        let device = FakeTunerDevice([.accept("tuner2")])
        let broker = Self.broker(device)
        let subscription = try await broker.subscribe(Self.request())
        #expect(subscription.route.resource == "tuner2")
        #expect(subscription.route.channel == Self.channel)
        #expect(subscription.route.deviceID == Self.deviceA)
        #expect(subscription.programNumber == nil)
        #expect(await broker.currentRoute == subscription.route)

        let upstream = try #require(device.streams.first)
        upstream.send(Data([0x47, 1]))
        upstream.send(Data([0x47, 2]))
        upstream.end()
        var received: [TSChunk] = []
        for try await chunk in subscription.chunks { received.append(chunk) }
        #expect(received == [.data(Data([0x47, 1])), .data(Data([0x47, 2]))])
        #expect(try await Self.eventually { await broker.currentRoute == nil })
    }

    @Test func aNewSubscriptionClosesTheOldOneBeforeItsGET() async throws {
        let device = FakeTunerDevice()
        let broker = Self.broker(device)
        let first = try await broker.subscribe(Self.request())
        let second = try await broker.subscribe(Self.request())
        #expect(device.requests.count == 2)
        #expect(device.heldAtRequest == [0, 0])
        #expect(device.maxHeld == 1)
        #expect(first.isEnded)
        #expect(!second.isEnded)
        await #expect(throws: HDHomeRunClientError.cancelled) {
            for try await _ in first.chunks {}
        }
    }

    @Test func cancelReleasesTheTuner() async throws {
        let device = FakeTunerDevice()
        let broker = Self.broker(device)
        var events = broker.events.makeAsyncIterator()
        let subscription = try await broker.subscribe(Self.request())
        #expect(await events.next() == .opened(subscription.route))
        subscription.cancel()
        #expect(device.held == 0)
        #expect(await events.next() == .closed(subscription.route, .cancelled))
        #expect(await broker.currentRoute == nil)
    }

    @Test func releaseAllClosesTheStream() async throws {
        let device = FakeTunerDevice()
        let broker = Self.broker(device)
        let subscription = try await broker.subscribe(Self.request())
        await broker.releaseAll()
        #expect(subscription.isEnded)
        #expect(device.held == 0)
    }

    @Test func busyRightAfterOurOwnReleaseIsRetriedOnce() async throws {
        let device = FakeTunerDevice([.accept("tuner1"), .fail(.allTunersInUse), .accept("tuner3")])
        let broker = Self.broker(device)
        _ = try await broker.subscribe(Self.request())
        let second = try await broker.subscribe(Self.request())
        #expect(second.route.resource == "tuner3")
        #expect(device.requests.count == 3)
        #expect(device.maxHeld == 1)
    }

    @Test func busyIsRetriedOnlyOnce() async throws {
        let device = FakeTunerDevice([.accept("tuner1"), .fail(.allTunersInUse), .fail(.allTunersInUse)])
        let broker = Self.broker(device)
        _ = try await broker.subscribe(Self.request())
        await #expect(throws: HDHomeRunClientError.allTunersInUse) {
            _ = try await broker.subscribe(Self.request())
        }
        #expect(device.requests.count == 3)
    }

    @Test func busyWithoutARecentReleaseIsNotRetried() async throws {
        let device = FakeTunerDevice([.fail(.allTunersInUse)])
        let broker = Self.broker(device)
        await #expect(throws: HDHomeRunClientError.allTunersInUse) {
            _ = try await broker.subscribe(Self.request())
        }
        #expect(device.requests.count == 1)
    }

    @Test func otherErrorsAreNotRetried() async throws {
        let device = FakeTunerDevice([.fail(.contentProtectionRequired)])
        let broker = Self.broker(device)
        await #expect(throws: HDHomeRunClientError.contentProtectionRequired) {
            _ = try await broker.subscribe(Self.request([Self.refA, Self.refB]))
        }
        #expect(device.requests.count == 1)
    }

    @Test func failsOverToTheNextDevice() async throws {
        let device = FakeTunerDevice([.fail(.noVideoData), .accept("tuner0")])
        let broker = Self.broker(device)
        let subscription = try await broker.subscribe(Self.request([Self.refA, Self.refB]))
        #expect(subscription.route.deviceID == Self.deviceB)
        #expect(device.requests == [Self.refA.url, Self.refB.url])
    }

    @Test func aSupersededSubscribeIsAbandoned() async throws {
        let device = FakeTunerDevice([.hang, .accept("tuner2")])
        let broker = Self.broker(device)
        let first = Task { try await broker.subscribe(Self.request()) }
        #expect(try await Self.eventually { device.requests.count == 1 })
        let second = try await broker.subscribe(Self.request())
        await #expect(throws: HDHomeRunClientError.cancelled) { _ = try await first.value }
        #expect(second.route.resource == "tuner2")
        #expect(device.heldAtRequest == [0, 0])
        #expect(device.maxHeld == 1)
    }

    @Test func cancellingTheCallerAbandonsTheRequest() async throws {
        let device = FakeTunerDevice([.hang])
        let broker = Self.broker(device)
        let waiting = Task { try await broker.subscribe(Self.request()) }
        #expect(try await Self.eventually { device.requests.count == 1 })
        waiting.cancel()
        await #expect(throws: HDHomeRunClientError.cancelled) { _ = try await waiting.value }
        #expect(device.held == 0)
        #expect(await broker.currentRoute == nil)
    }

    @Test func midStreamFailuresReachTheSubscriber() async throws {
        let device = FakeTunerDevice()
        let broker = Self.broker(device)
        var events = broker.events.makeAsyncIterator()
        let subscription = try await broker.subscribe(Self.request())
        _ = await events.next()
        try #require(device.streams.first).fail(.connectionLost)
        await #expect(throws: HDHomeRunClientError.connectionLost) {
            for try await _ in subscription.chunks {}
        }
        #expect(await events.next() == .closed(subscription.route, .failed(.connectionLost)))
    }
}

/// The free-tuner check made before tiles and background work, never before the stream the user starts.
@Suite("TunerBroker free-tuner check", .timeLimit(.minutes(1)))
struct TunerBrokerCapacityTests {
    private final class StatusSource: Sendable {
        let statuses: [TunerStatus]
        private let counter = Counter()
        init(free: Int, busy: Int) {
            statuses = (0..<free).map { TunerStatus(resource: "tuner\($0)") }
                + (0..<busy).map { TunerStatus(resource: "tuner\(free + $0)", vctNumber: "9.1",
                                               targetIP: "192.0.2.44") }
        }
        var fetches: Int { counter.value }
        var fetcher: TunerBroker.StatusFetcher {
            { [self] _ in
                counter.increment()
                return statuses
            }
        }
    }

    @Test func aTileNeedsAFreeTunerAfterTheReserve() async throws {
        let device = FakeTunerDevice()
        let source = StatusSource(free: 1, busy: 3)
        let broker = TunerBrokerTests.broker(device, fetchStatus: source.fetcher)
        await #expect(throws: HDHomeRunClientError.allTunersInUse) {
            _ = try await broker.subscribe(TunerBrokerTests.request(purpose: .tile))
        }
        #expect(device.requests.isEmpty)
        #expect(source.fetches == 1)
    }

    @Test func aTileTunesWhenEnoughAreFreeAndReusesAFreshStatus() async throws {
        let device = FakeTunerDevice()
        let source = StatusSource(free: 2, busy: 2)
        let broker = TunerBrokerTests.broker(device, fetchStatus: source.fetcher)
        _ = try await broker.subscribe(TunerBrokerTests.request(purpose: .tile))
        _ = try await broker.subscribe(TunerBrokerTests.request(purpose: .tile))
        #expect(device.requests.count == 2)
        #expect(source.fetches == 1)
    }

    @Test func watchingIsNeverBlockedByTheCheck() async throws {
        let device = FakeTunerDevice()
        let source = StatusSource(free: 0, busy: 4)
        let broker = TunerBrokerTests.broker(device, fetchStatus: source.fetcher)
        _ = try await broker.subscribe(TunerBrokerTests.request(purpose: .watch))
        #expect(device.requests.count == 1)
        #expect(source.fetches == 0)
    }

    @Test func capacityCountsOurStreamAsOurs() async throws {
        let device = FakeTunerDevice([.accept("tuner3")])
        let source = StatusSource(free: 2, busy: 2)
        let broker = TunerBrokerTests.broker(device, fetchStatus: source.fetcher)
        _ = try await broker.subscribe(TunerBrokerTests.request())
        let capacity = try await broker.capacity(of: TunerBrokerTests.refA)
        #expect(capacity.free.count == 2)
        #expect(capacity.ours.map(\.resource) == ["tuner3"])
        #expect(capacity.others.map(\.resource) == ["tuner2"])
    }
}

private nonisolated final class Counter: Sendable {
    private let storage = Mutex(0)
    var value: Int { storage.withLock { $0 } }
    func increment() { storage.withLock { $0 += 1 } }
}
