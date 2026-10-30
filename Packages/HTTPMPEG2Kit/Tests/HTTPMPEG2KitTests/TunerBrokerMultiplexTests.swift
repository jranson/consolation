import Foundation
import Testing
@testable import HTTPMPEG2Kit

/// Multiplex sharing in the broker: `/tuner<N>/ch<frequency>` on a named tuner without ATSC 3.0, channels on an
/// open multiplex joining at zero cost with their program number, the policy, 804 re-planning and the re-tune
/// offer. Fixture channels: 2.1 (program 6) and 31.1 (program 3) share 605 MHz. No request leaves the process.
@Suite("TunerBroker multiplex", .timeLimit(.minutes(1)))
struct TunerBrokerMultiplexTests {
    static let device = MultiView.deviceA.rawValue

    static func flexWithFree(_ free: Set<Int>) -> StatusBoard {
        let status = StatusBoard()
        status.set(device, free: free)
        return status
    }

    @Test func aTileOnAnOpenMultiplexJoinsAtZeroCost() async throws {
        let device = FakeTunerDevice([.accept("tuner3")])
        let broker = MultiView.broker(device, status: Self.flexWithFree([0, 1, 3]), policy: .always)
        let first = try await broker.subscribe(MultiView.request("2.1"), slot: MultiView.tile())
        #expect(device.requests.map(\.path) == ["/tuner3/ch605000000"])
        #expect(device.requests.first?.host() == "192.0.2.10")
        #expect(first.programNumber == 6)
        #expect(first.route.frequency == 605_000_000)
        #expect(first.route.isMultiplex)

        let second = try await broker.subscribe(MultiView.request("31.1"), slot: MultiView.tile())
        let player = try await broker.subscribe(MultiView.request("31.1", purpose: .watch))
        #expect(device.requests.count == 1)
        #expect(second.programNumber == 3)
        #expect(second.route.channel == MultiView.key("31.1"))
        #expect(second.route.resource == "tuner3")
        #expect(player.programNumber == 3)
        #expect(await broker.subscriberCount(for: MultiView.key("31.1")) == 2)
        #expect(await broker.subscriberCount(for: MultiView.key("2.1")) == 1)

        // Every subscriber reads the whole multiplex and selects its own program.
        try #require(device.streams.first).send(Data([0x47, 0x00]))
        var bytes = second.chunks.makeAsyncIterator()
        #expect(try await bytes.next() == .data(Data([0x47, 0x00])))

        first.cancel()
        second.cancel()
        #expect(device.held == 1)
        player.cancel()
        #expect(device.held == 0)
    }

    @Test func policyNeverOpensProgramStreams() async throws {
        let device = FakeTunerDevice([.accept("tuner3"), .accept("tuner1")])
        let broker = MultiView.broker(device, status: Self.flexWithFree([0, 1, 3]), policy: .never)
        let first = try await broker.subscribe(MultiView.request("2.1", prefersMultiplex: true),
                                               slot: MultiView.tile())
        let second = try await broker.subscribe(MultiView.request("31.1"), slot: MultiView.tile())
        #expect(device.requests.map(\.path) == ["/auto/v2.1", "/auto/v31.1"])
        #expect(first.programNumber == nil)
        #expect(second.programNumber == nil)
        #expect(!first.route.isMultiplex)
    }

    @Test func whenTunersAreShortOpensAMultiplexOnlyWhenAsked() async throws {
        let device = FakeTunerDevice([.accept("tuner1"), .accept("tuner3")])
        let broker = MultiView.broker(device, status: Self.flexWithFree([0, 1, 3]))
        _ = try await broker.subscribe(MultiView.request("4.1"), slot: MultiView.tile())
        let shared = try await broker.subscribe(MultiView.request("2.1", prefersMultiplex: true),
                                                slot: MultiView.tile())
        #expect(device.requests.map(\.path) == ["/auto/v4.1", "/tuner3/ch605000000"])
        #expect(shared.programNumber == 6)
        await broker.setMultiplexPolicy(.never)
        #expect(await broker.multiplexPolicy == .never)
    }

    @Test func theSingleViewPlayerOpensAProgramStreamEvenWithPolicyAlways() async throws {
        let device = FakeTunerDevice()
        let broker = MultiView.broker(device, status: Self.flexWithFree([0, 1, 3]), policy: .always)
        let player = try await broker.subscribe(MultiView.request("2.1", purpose: .watch))
        #expect(device.requests.map(\.path) == ["/auto/v2.1"])
        #expect(player.programNumber == nil)
    }

    @Test func aTakenTunerIsReplannedOn804() async throws {
        let device = FakeTunerDevice([.fail(.tunerInUse), .accept("tuner0")])
        let status = Self.flexWithFree([0, 3])
        let broker = MultiView.broker(device, status: status, policy: .always)
        let tile = try await broker.subscribe(MultiView.request("2.1"), slot: MultiView.tile())
        #expect(device.requests.map(\.path) == ["/tuner3/ch605000000", "/tuner0/ch605000000"])
        #expect(tile.route.resource == "tuner0")
        #expect(tile.programNumber == 6)
        #expect(device.maxHeld == 1)
    }

    @Test func withNoTunerLeftToNameItFallsBackToAProgramStream() async throws {
        let device = FakeTunerDevice([.fail(.tunerInUse), .accept("tuner2")])
        let broker = MultiView.broker(device, status: Self.flexWithFree([3]), policy: .always)
        let tile = try await broker.subscribe(MultiView.request("2.1"), slot: MultiView.tile())
        #expect(device.requests.map(\.path) == ["/tuner3/ch605000000", "/auto/v2.1"])
        #expect(tile.programNumber == nil)
    }

    @Test func twoTilesOpeningOneMultiplexAtOnceTakeOneTuner() async throws {
        let device = FakeTunerDevice([.delayed("tuner3", .milliseconds(100))])
        let broker = MultiView.broker(device, status: Self.flexWithFree([0, 1, 3]))
        let first = Task {
            try await broker.subscribe(MultiView.request("2.1", prefersMultiplex: true), slot: MultiView.tile())
        }
        #expect(try await TunerBrokerTests.eventually { device.requests.count == 1 })
        let second = try await broker.subscribe(MultiView.request("31.1", prefersMultiplex: true),
                                                slot: MultiView.tile())
        #expect(try await first.value.programNumber == 6)
        #expect(second.programNumber == 3)
        #expect(device.requests.count == 1)
    }

    @Test func aSecondChannelOnAFullDeviceIsOfferedTheRetune() async throws {
        let device = FakeTunerDevice([.accept("tuner3"), .accept("tuner3")])
        let status = Self.flexWithFree([3])
        let broker = MultiView.broker(device, status: status)
        let tileA = MultiView.tile()
        let tileB = MultiView.tile()
        let first = try await broker.subscribe(MultiView.request("2.1"), slot: tileA)
        #expect(first.programNumber == nil)
        status.set(Self.device, free: [])

        let admission = await broker.admission(for: MultiView.request("31.1"))
        #expect(admission == .retuneOntoMultiplex(slot: tileA, channel: MultiView.key("2.1"),
                                                   deviceID: MultiView.deviceA, frequency: 605_000_000))
        #expect(!admission.isAvailable)

        // The app re-tunes tile A onto the multiplex (its own tuner, named), then tile B joins it at zero cost.
        let retuned = try await broker.subscribe(MultiView.request("2.1", prefersMultiplex: true), slot: tileA)
        let second = try await broker.subscribe(MultiView.request("31.1"), slot: tileB)
        #expect(device.requests.map(\.path) == ["/auto/v2.1", "/tuner3/ch605000000"])
        #expect(device.heldAtRequest == [0, 0])
        #expect(first.isEnded)
        #expect(retuned.programNumber == 6)
        #expect(second.programNumber == 3)
    }

    @Test func noRetuneOfferWithPolicyNever() async throws {
        let device = FakeTunerDevice()
        let status = Self.flexWithFree([3])
        let broker = MultiView.broker(device, status: status, policy: .never)
        _ = try await broker.subscribe(MultiView.request("2.1"), slot: MultiView.tile())
        status.set(Self.device, free: [])
        guard case .unavailable(.noFreeTuner) = await broker.admission(for: MultiView.request("31.1")) else {
            Issue.record("expected no free tuner")
            return
        }
    }

    @Test func relayClientsCantAttachToAMultiplexChannel() async throws {
        let device = FakeTunerDevice()
        let broker = MultiView.broker(device, status: Self.flexWithFree([0, 1, 3]), policy: .always)
        _ = try await broker.subscribe(MultiView.request("2.1"), slot: MultiView.tile())
        await #expect(throws: HDHomeRunClientError.unknownChannel) {
            _ = try await broker.attach(to: MultiView.key("2.1"))
        }
    }

    @Test func multiplexURLKeepsTheDeviceAndNamesTheTuner() throws {
        let ref = MultiView.ref("31.1")
        #expect(ref.multiplexURL(tuner: 2)?.absoluteString == "http://192.0.2.10:5004/tuner2/ch605000000")
        #expect(ref.canShareMultiplex)
        #expect(!MultiView.ref("102.1").canShareMultiplex)
        #expect(MultiView.ref("102.1").isATSC3)
    }
}
