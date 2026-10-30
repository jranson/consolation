import Foundation
import Testing
@testable import HTTPMPEG2Kit

/// The tile picker's data: admission with the reserve at 1 and 0, free joins, ATSC 3.0 tuners, the runtime reserve
/// and the per-device capacity summary. No request leaves the process.
@Suite("TunerBroker admission", .timeLimit(.minutes(1)))
struct TunerBrokerAdmissionTests {
    static let device = MultiView.deviceA.rawValue

    static func board(free: Set<Int>) -> StatusBoard {
        let status = StatusBoard()
        status.set(device, free: free)
        return status
    }

    @Test func withTheReserveAtOneATileNeedsTwoFreeTuners() async throws {
        let status = Self.board(free: [1, 3])
        let broker = MultiView.broker(FakeTunerDevice(), status: status, reserve: 1)
        let admission = await broker.admission(for: MultiView.request("9.1"))
        guard case let .needsTuner(deviceID, capacity, takesLast) = admission else {
            Issue.record("expected a tuner on device A")
            return
        }
        #expect(deviceID == MultiView.deviceA)
        #expect(capacity?.free == 2)
        #expect(capacity?.availableAfterReserve == 1)
        #expect(!takesLast)

        status.set(Self.device, free: [3])
        guard case .unavailable(.noFreeTuner(let devices)) = await broker.admission(for: MultiView.request("9.1"))
        else {
            Issue.record("expected no free tuner after the reserve")
            return
        }
        #expect(devices.map(\.free) == [1])
        #expect(devices.first?.availableAfterReserve == 0)
    }

    @Test func withTheReserveAtZeroTheLastFreeTunerIsFlagged() async throws {
        let status = Self.board(free: [3])
        let broker = MultiView.broker(FakeTunerDevice(), status: status, reserve: 1)
        #expect(!(await broker.admission(for: MultiView.request("9.1"))).isAvailable)
        await broker.setReserve(0)
        #expect(await broker.reserve == 0)
        let admission = await broker.admission(for: MultiView.request("9.1"))
        guard case .needsTuner(_, _, let takesLast) = admission else {
            Issue.record("expected a tuner")
            return
        }
        #expect(takesLast)
        #expect(admission.isAvailable)
    }

    @Test func theReserveAppliesToSubscribesToo() async throws {
        let device = FakeTunerDevice()
        let broker = MultiView.broker(device, status: Self.board(free: [3]), reserve: 1)
        await #expect(throws: HDHomeRunClientError.allTunersInUse) {
            _ = try await broker.subscribe(MultiView.request("9.1"), slot: MultiView.tile())
        }
        await broker.setReserve(0)
        _ = try await broker.subscribe(MultiView.request("9.1"), slot: MultiView.tile())
        #expect(device.requests.count == 1)
    }

    @Test func watchingIsNeverRefused() async throws {
        let broker = MultiView.broker(FakeTunerDevice(), status: Self.board(free: []), reserve: 1)
        let admission = await broker.admission(for: MultiView.request("9.1", purpose: .watch))
        guard case .needsTuner(_, let capacity, false) = admission else {
            Issue.record("expected .needsTuner")
            return
        }
        #expect(capacity?.free == 0)
    }

    @Test func anOpenChannelOrMultiplexCostsNothing() async throws {
        let device = FakeTunerDevice([.accept("tuner3"), .accept("tuner1")])
        let broker = MultiView.broker(device, status: Self.board(free: [0, 1, 3]), policy: .always)
        _ = try await broker.subscribe(MultiView.request("2.1"), slot: MultiView.tile())
        _ = try await broker.subscribe(MultiView.request("9.1", purpose: .watch))
        guard case .free(let onMultiplex) = await broker.admission(for: MultiView.request("31.1")),
              case .free(let duplicate) = await broker.admission(for: MultiView.request("9.1")) else {
            Issue.record("expected free joins")
            return
        }
        #expect(onMultiplex.programNumber == 3)
        #expect(onMultiplex.resource == "tuner3")
        #expect(duplicate.channel == MultiView.key("9.1"))
        #expect(duplicate.programNumber == nil)
    }

    @Test func atsc3NeedsACapableTuner() async throws {
        let broker = MultiView.broker(FakeTunerDevice(), status: Self.board(free: [2, 3]))
        guard case .unavailable(.atsc3TunersBusy(let devices)) = await broker.admission(
            for: MultiView.request("102.1")) else {
            Issue.record("expected ATSC 3.0 tuners busy")
            return
        }
        #expect(devices.first?.freeATSC3Capable == 0)
        #expect(devices.first?.free == 2)
    }

    @Test func withoutAStatusReaderTilesAreUnavailable() async throws {
        let broker = MultiView.broker(FakeTunerDevice())
        #expect(await broker.admission(for: MultiView.request("9.1")) == .unavailable(.statusUnavailable))
        let empty = TuneRequest(channel: MultiView.key("9.1"), routes: [], purpose: .tile)
        #expect(await broker.admission(for: empty) == .unavailable(.noRoutes))
    }

    @Test func capacitySummaryNamesOursAndOthers() async throws {
        let device = FakeTunerDevice([.accept("tuner3")])
        let status = StatusBoard()
        status.set(Self.device, try Fixture.tunerStatus("status_two-in-use"))
        let broker = MultiView.broker(device, status: status, reserve: 1)
        _ = try await broker.subscribe(MultiView.request("31.1", purpose: .watch))
        let summary = try await broker.capacitySummary(of: MultiView.ref("31.1"))
        // "2 of 4 tuners free (1 in use by 192.0.2.44)", one of them ours.
        #expect(summary.total == 4)
        #expect(summary.free == 2)
        #expect(summary.ours == 1)
        #expect(summary.others.map(\.targetIP) == ["192.0.2.44"])
        #expect(summary.others.map(\.vctNumber) == ["7.1"])
        #expect(summary.availableAfterReserve == 1)
        #expect(summary.freeATSC3Capable == 2)
        let summaries = await broker.capacitySummaries(of: [MultiView.ref("31.1"), MultiView.ref("2.1"),
                                                            MultiView.ref("2.1", on: MultiView.deviceB)])
        #expect(summaries.map(\.deviceID) == [MultiView.deviceA])
    }

    @Test func thePlanUsesTheReserveAndThePolicy() async throws {
        let broker = MultiView.broker(FakeTunerDevice(), status: Self.board(free: [0, 1, 3]))
        let favorites = ["2.1", "4.1", "31.1", "9.1", "7.1"].map { MultiView.request($0) }
        let plan = await broker.plan(favorites)
        #expect(plan.multiplexedChannels == [MultiView.key("2.1"), MultiView.key("31.1")])
        #expect(plan.unplaced == [MultiView.key("7.1")])
        await broker.setReserve(3)
        #expect(await broker.plan(favorites).streams.isEmpty)
    }
}
