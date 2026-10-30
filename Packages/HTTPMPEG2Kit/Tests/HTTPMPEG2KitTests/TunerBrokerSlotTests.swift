import Foundation
import Testing
@testable import HTTPMPEG2Kit

/// Subscriber slots: the player and each tile hold one subscription each, close before open within a slot, shared
/// upstreams across slots, and relay-only upstreams making way for any slot. No request leaves the process.
@Suite("TunerBroker slots", .timeLimit(.minutes(1)))
struct TunerBrokerSlotTests {
    static func watch(_ guideNumber: String) -> TuneRequest {
        MultiView.request(guideNumber, purpose: .watch)
    }

    @Test func aTileDoesNotReplaceThePlayer() async throws {
        let device = FakeTunerDevice([.accept("tuner3"), .accept("tuner2")])
        let broker = MultiView.broker(device)
        let tile = MultiView.tile()
        let player = try await broker.subscribe(Self.watch("9.1"))
        let tiled = try await broker.subscribe(Self.watch("7.1"), slot: tile)
        #expect(!player.isEnded)
        #expect(!tiled.isEnded)
        #expect(device.held == 2)
        #expect(await broker.route(of: .player) == player.route)
        #expect(await broker.route(of: tile) == tiled.route)
        #expect(await broker.currentRoute == player.route)
    }

    @Test func eachSlotClosesBeforeItOpens() async throws {
        let device = FakeTunerDevice()
        let broker = MultiView.broker(device)
        let tile = MultiView.tile()
        let player = try await broker.subscribe(Self.watch("9.1"))
        let first = try await broker.subscribe(Self.watch("7.1"), slot: tile)
        let second = try await broker.subscribe(Self.watch("4.1"), slot: tile)
        #expect(first.isEnded)
        #expect(!second.isEnded)
        #expect(!player.isEnded)
        // The tile's flip never held two tuners: one for the player, one for the tile.
        #expect(device.heldAtRequest == [0, 1, 1])
        #expect(device.maxHeld == 2)
    }

    @Test func aTileInFlightIsNotCancelledByAnotherSlot() async throws {
        let device = FakeTunerDevice([.hang, .accept("tuner2")])
        let broker = MultiView.broker(device)
        let tile = MultiView.tile()
        let waiting = Task { try await broker.subscribe(Self.watch("7.1"), slot: tile) }
        #expect(try await TunerBrokerTests.eventually { device.requests.count == 1 })
        let player = try await broker.subscribe(Self.watch("9.1"))
        #expect(!player.isEnded)
        #expect(try #require(device.streams.first).isCancelled == false)
        await broker.release(slot: tile)
        await #expect(throws: HDHomeRunClientError.cancelled) { _ = try await waiting.value }
        #expect(device.held == 1)
    }

    @Test func theSameChannelInTwoSlotsIsOneUpstream() async throws {
        let device = FakeTunerDevice()
        let broker = MultiView.broker(device)
        let player = try await broker.subscribe(Self.watch("9.1"))
        let tile = try await broker.subscribe(Self.watch("9.1"), slot: MultiView.tile())
        #expect(device.requests.count == 1)
        #expect(await broker.subscriberCount(for: MultiView.key("9.1")) == 2)
        try #require(device.streams.first).send(Data([0x47, 9]))
        var playerBytes = player.chunks.makeAsyncIterator()
        var tileBytes = tile.chunks.makeAsyncIterator()
        #expect(try await playerBytes.next() == .data(Data([0x47, 9])))
        #expect(try await tileBytes.next() == .data(Data([0x47, 9])))
    }

    @Test func theLastSlotToCancelClosesTheUpstream() async throws {
        let device = FakeTunerDevice()
        let broker = MultiView.broker(device)
        var events = broker.events.makeAsyncIterator()
        let player = try await broker.subscribe(Self.watch("9.1"))
        let tile = try await broker.subscribe(Self.watch("9.1"), slot: MultiView.tile())
        #expect(await events.next() == .opened(player.route))
        player.cancel()
        #expect(device.held == 1)
        #expect(!tile.isEnded)
        tile.cancel()
        #expect(device.held == 0)
        #expect(await events.next() == .closed(tile.route, .cancelled))
        #expect(await broker.openRoutes.isEmpty)
    }

    @Test func releasingASlotKeepsTheOthers() async throws {
        let device = FakeTunerDevice()
        let broker = MultiView.broker(device)
        let tileA = MultiView.tile()
        let tileB = MultiView.tile()
        let first = try await broker.subscribe(Self.watch("9.1"), slot: tileA)
        let second = try await broker.subscribe(Self.watch("7.1"), slot: tileB)
        let shared = try await broker.subscribe(Self.watch("9.1"))
        await broker.release(slot: tileA)
        #expect(first.isEnded)
        #expect(!shared.isEnded)
        #expect(!second.isEnded)
        #expect(device.held == 2)
        await broker.releaseAll()
        #expect(device.held == 0)
        #expect(await broker.route(of: tileB) == nil)
    }

    @Test func twoTilesAskingForOneChannelAtOnceTakeOneTuner() async throws {
        let device = FakeTunerDevice([.delayed("tuner3", .milliseconds(100))])
        let broker = MultiView.broker(device)
        let first = Task { try await broker.subscribe(Self.watch("9.1"), slot: MultiView.tile()) }
        #expect(try await TunerBrokerTests.eventually { device.requests.count == 1 })
        let second = try await broker.subscribe(Self.watch("9.1"), slot: MultiView.tile())
        let opened = try await first.value
        #expect(device.requests.count == 1)
        #expect(second.route == opened.route)
        #expect(await broker.subscriberCount(for: MultiView.key("9.1")) == 2)
    }

    @Test func relayOnlyUpstreamsMakeWayForATile() async throws {
        let device = FakeTunerDevice()
        let status = StatusBoard()
        // tuner0 carries the relay-only upstream; every other tuner is held by another client.
        status.set(MultiView.deviceA.rawValue, free: [])
        let broker = MultiView.broker(device, status: status)
        _ = try await broker.subscribe(Self.watch("9.1"))
        let relay = try await broker.attach(to: MultiView.key("9.1"))
        await broker.release(slot: .player)
        #expect(!relay.isEnded)
        let tile = try await broker.subscribe(MultiView.request("7.1"), slot: MultiView.tile())
        #expect(relay.isEnded)
        #expect(!tile.isEnded)
        #expect(device.heldAtRequest == [0, 0])
        #expect(device.maxHeld == 1)
    }

    @Test func anUpstreamATileReadsIsNotRelayOnly() async throws {
        let device = FakeTunerDevice()
        let status = StatusBoard()
        status.set(MultiView.deviceA.rawValue, free: [])
        let broker = MultiView.broker(device, status: status)
        _ = try await broker.subscribe(Self.watch("9.1"))
        let relay = try await broker.attach(to: MultiView.key("9.1"))
        let tile = try await broker.subscribe(Self.watch("9.1"), slot: MultiView.tile())
        // The player switches with no tuner free: the 9.1 upstream stays, because a tile still reads it.
        _ = try await broker.subscribe(Self.watch("7.1"))
        #expect(!relay.isEnded)
        #expect(!tile.isEnded)
        #expect(device.requests.count == 2)
    }
}
