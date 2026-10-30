import Foundation
import Testing
@testable import HTTPMPEG2Kit

/// Several devices carrying one channel: the broker's device order (a free tuner after the reserve, then signal
/// quality, then most free tuners), failover on 805/806/807, and reconnects avoiding a device that just failed. Device
/// A is at 192.0.2.10, B at 192.0.2.11. No request leaves the process.
@Suite("TunerBroker device choice", .timeLimit(.minutes(1)))
struct TunerBrokerDeviceChoiceTests {
    static let both = [MultiView.deviceA, MultiView.deviceB]

    static func status(freeA: Set<Int>, freeB: Set<Int>) -> StatusBoard {
        let status = StatusBoard()
        status.set(MultiView.deviceA.rawValue, free: freeA)
        status.set(MultiView.deviceB.rawValue, free: freeB)
        return status
    }

    static func hosts(_ device: FakeTunerDevice) -> [String?] {
        device.requests.map { $0.host() }
    }

    @Test(arguments: [HDHomeRunClientError.allTunersInUse, .tuneFailed, .noVideoData])
    func aTileFailsOverToTheNextDevice(_ error: HDHomeRunClientError) async throws {
        let device = FakeTunerDevice([.fail(error), .accept("tuner1")])
        let broker = MultiView.broker(device, status: Self.status(freeA: [0, 1, 2, 3], freeB: [0, 1, 2, 3]))
        let tile = try await broker.subscribe(MultiView.request("9.1", devices: Self.both), slot: MultiView.tile())
        #expect(tile.route.deviceID == MultiView.deviceB)
        #expect(Self.hosts(device) == ["192.0.2.10", "192.0.2.11"])
    }

    @Test func otherErrorsDontFailOver() async throws {
        let device = FakeTunerDevice([.fail(.unknownChannel)])
        let broker = MultiView.broker(device, status: Self.status(freeA: [0, 1], freeB: [0, 1]))
        await #expect(throws: HDHomeRunClientError.unknownChannel) {
            _ = try await broker.subscribe(MultiView.request("9.1", devices: Self.both), slot: MultiView.tile())
        }
        #expect(device.requests.count == 1)
    }

    @Test func aDeviceWithAFreeTunerAfterTheReserveComesFirst() async throws {
        let device = FakeTunerDevice()
        let broker = MultiView.broker(device, status: Self.status(freeA: [3], freeB: [2, 3]), reserve: 1)
        let tile = try await broker.subscribe(MultiView.request("9.1", devices: Self.both), slot: MultiView.tile())
        #expect(tile.route.deviceID == MultiView.deviceB)
        #expect(Self.hosts(device) == ["192.0.2.11"])
    }

    @Test func thenTheBestSignal() async throws {
        let device = FakeTunerDevice()
        let broker = MultiView.broker(device, status: Self.status(freeA: [0, 1, 2, 3], freeB: [3]))
        let request = TuneRequest(channel: MultiView.key("9.1"),
                                  routes: [MultiView.ref("9.1", on: MultiView.deviceA, signalQuality: 60),
                                           MultiView.ref("9.1", on: MultiView.deviceB, signalQuality: 95)],
                                  purpose: .tile)
        _ = try await broker.subscribe(request, slot: MultiView.tile())
        #expect(Self.hosts(device) == ["192.0.2.11"])
    }

    @Test func thenTheMostFreeTuners() async throws {
        let device = FakeTunerDevice()
        let broker = MultiView.broker(device, status: Self.status(freeA: [3], freeB: [1, 2, 3]))
        _ = try await broker.subscribe(MultiView.request("9.1", devices: Self.both), slot: MultiView.tile())
        #expect(Self.hosts(device) == ["192.0.2.11"])
    }

    @Test func aWatchWithOneRouteNeverReadsStatus() async throws {
        let device = FakeTunerDevice()
        let status = Self.status(freeA: [], freeB: [])
        let broker = MultiView.broker(device, status: status, reserve: 1)
        _ = try await broker.subscribe(MultiView.request("9.1", purpose: .watch))
        #expect(status.fetches == 0)
        #expect(device.requests.count == 1)
    }

    @Test func aWatchWithSeveralRoutesIsOrderedButNeverBlocked() async throws {
        let device = FakeTunerDevice([.fail(.allTunersInUse), .accept("tuner0")])
        let broker = MultiView.broker(device, status: Self.status(freeA: [], freeB: [2]), reserve: 1)
        let player = try await broker.subscribe(MultiView.request("9.1", purpose: .watch, devices: Self.both))
        // B has a free tuner, so it goes first; it answered 805 anyway, and A (no free tuner) still gets its GET.
        #expect(Self.hosts(device) == ["192.0.2.11", "192.0.2.10"])
        #expect(player.route.deviceID == MultiView.deviceA)
    }

    @Test func aReconnectAfterAFailureTriesAnotherDeviceFirst() async throws {
        let device = FakeTunerDevice()
        let broker = MultiView.broker(device)
        let tile = MultiView.tile()
        let request = MultiView.request("9.1", purpose: .watch, devices: Self.both)
        let first = try await broker.subscribe(request, slot: tile)
        #expect(first.route.deviceID == MultiView.deviceA)
        try #require(device.streams.first).fail(.connectionLost)
        #expect(try await TunerBrokerTests.eventually { await broker.openRoutes.isEmpty })
        // The engine reconnects: the same request and slot. Device A just failed, so B goes first.
        let again = try await broker.subscribe(request, slot: tile)
        #expect(again.route.deviceID == MultiView.deviceB)
        #expect(Self.hosts(device) == ["192.0.2.10", "192.0.2.11"])
    }

    @Test func aReconnectThatGets805FailsOverThroughTheRoutes() async throws {
        let device = FakeTunerDevice([.accept("tuner1"), .fail(.allTunersInUse), .fail(.allTunersInUse),
                                      .accept("tuner2")])
        let broker = MultiView.broker(device)
        let tile = MultiView.tile()
        let request = MultiView.request("9.1", purpose: .watch, devices: Self.both)
        _ = try await broker.subscribe(request, slot: tile)
        try #require(device.streams.first).fail(.connectionLost)
        #expect(try await TunerBrokerTests.eventually { await broker.openRoutes.isEmpty })
        // B first (A just failed): 805, retried once because we released a tuner a moment ago, 805 again; then A.
        let again = try await broker.subscribe(request, slot: tile)
        #expect(again.route.resource == "tuner2")
        #expect(again.route.deviceID == MultiView.deviceA)
        #expect(Self.hosts(device) == ["192.0.2.10", "192.0.2.11", "192.0.2.11", "192.0.2.10"])
    }
}
