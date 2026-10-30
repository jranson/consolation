import Foundation
import Testing
@testable import HTTPMPEG2Kit

/// The planner on the rewritten FLEX 4K `?show=all&tuning` lineup: multiplex sharing, duplicates, ATSC 3.0 tuners and
/// the policy.
@Suite("MultiViewPlanner")
struct MultiViewPlannerTests {
    static let device = Fixture.deviceID
    static let favorites = ["2.1", "4.1", "31.1", "9.1", "7.1"]

    static func channels(_ guideNumbers: [String]) throws -> [PlannerChannel] {
        let lineup = try Fixture.lineup("lineup_show-all_tuning")
        return try guideNumbers.map { guideNumber in
            let entry = try Fixture.channel(guideNumber, in: lineup)
            return PlannerChannel(channel: MultiView.key(guideNumber), device: device, frequency: entry.frequency,
                                  programNumber: entry.programNumber, isATSC3: entry.isATSC3)
        }
    }

    static func flex4K(free: [Int], reserve: Int = 0) -> DeviceTunerState {
        DeviceTunerState(device: device, freeTuners: free,
                         atsc3CapableTuners: TunerModelTable.atsc3CapableTuners(modelNumber: "HDFX-4K"),
                         reserve: reserve)
    }

    static func program(_ guideNumber: String) -> PlannedStream {
        .program(device: device, channel: MultiView.key(guideNumber))
    }

    @Test func favoritesShareTheMultiplexWhenTunersAreShort() throws {
        let plan = MultiViewPlanner.plan(requested: try Self.channels(Self.favorites),
                                         devices: [Self.flex4K(free: [0, 1, 3])], policy: .whenTunersAreShort)
        #expect(plan.streams == [
            .multiplex(device: Self.device, tuner: 3, frequency: 605_000_000, programs: [6, 3],
                       channels: [MultiView.key("2.1"), MultiView.key("31.1")]),
            Self.program("4.1"),
            Self.program("9.1")
        ])
        #expect(plan.unplaced == [MultiView.key("7.1")])
        #expect(plan.multiplexedChannels == [MultiView.key("2.1"), MultiView.key("31.1")])
    }

    @Test func enoughTunersMeansProgramStreams() throws {
        let plan = MultiViewPlanner.plan(requested: try Self.channels(["2.1", "31.1", "4.1"]),
                                         devices: [Self.flex4K(free: [0, 1, 2, 3])], policy: .whenTunersAreShort)
        #expect(plan.streams == [Self.program("2.1"), Self.program("31.1"), Self.program("4.1")])
        #expect(plan.unplaced.isEmpty)
    }

    @Test func duplicatesCollapse() throws {
        let plan = MultiViewPlanner.plan(requested: try Self.channels(["2.1", "4.1", "2.1", "4.1"]),
                                         devices: [Self.flex4K(free: [3])], policy: .never)
        #expect(plan.streams == [Self.program("2.1")])
        #expect(plan.unplaced == [MultiView.key("4.1")])
    }

    @Test func atsc3GoesOnlyToCapableTuners() throws {
        // 102.1 is ATSC 3.0. With only tuners 2 and 3 free (not 3.0-capable on the FLEX 4K) it can't be placed.
        let none = MultiViewPlanner.plan(requested: try Self.channels(["102.1"]),
                                         devices: [Self.flex4K(free: [2, 3])], policy: .always)
        #expect(none.streams.isEmpty)
        #expect(none.unplaced == [MultiView.key("102.1")])
        // ATSC 1.0 work takes the non-3.0 tuner first, leaving tuner 0 for 102.1, which is never multiplexed.
        let both = MultiViewPlanner.plan(requested: try Self.channels(["4.1", "102.1"]),
                                         devices: [Self.flex4K(free: [0, 3])], policy: .always)
        #expect(both.streams == [
            .multiplex(device: Self.device, tuner: 3, frequency: 599_000_000, programs: [1],
                       channels: [MultiView.key("4.1")]),
            Self.program("102.1")
        ])
        #expect(both.unplaced.isEmpty)
    }

    @Test func policyNeverYieldsProgramStreamsOnly() throws {
        let plan = MultiViewPlanner.plan(requested: try Self.channels(Self.favorites),
                                         devices: [Self.flex4K(free: [0, 1, 3])], policy: .never)
        #expect(plan.streams == [Self.program("2.1"), Self.program("4.1"), Self.program("31.1")])
        #expect(plan.unplaced == [MultiView.key("9.1"), MultiView.key("7.1")])
        #expect(plan.multiplexedChannels.isEmpty)
    }

    @Test func theReserveIsLeftFree() throws {
        let plan = MultiViewPlanner.plan(requested: try Self.channels(Self.favorites),
                                         devices: [Self.flex4K(free: [0, 1, 3], reserve: 1)],
                                         policy: .whenTunersAreShort)
        #expect(plan.streams.count == 2)
        #expect(plan.streams.first == .multiplex(device: Self.device, tuner: 3, frequency: 605_000_000,
                                                 programs: [6, 3],
                                                 channels: [MultiView.key("2.1"), MultiView.key("31.1")]))
        #expect(plan.unplaced == [MultiView.key("9.1"), MultiView.key("7.1")])
    }

    @Test func tunerChoicePrefersTunersWithoutATSC3() {
        let flex: Set<Int> = [0, 1]
        #expect(MultiViewPlanner.pickTuner(from: [0, 1, 3], atsc3Capable: flex, needsATSC3: false) == 3)
        #expect(MultiViewPlanner.pickTuner(from: [0, 1], atsc3Capable: flex, needsATSC3: false) == 0)
        #expect(MultiViewPlanner.pickTuner(from: [2, 3], atsc3Capable: flex, needsATSC3: true) == nil)
        #expect(MultiViewPlanner.pickTuner(from: [2, 3], atsc3Capable: nil, needsATSC3: true) == 2)
        #expect(TunerModelTable.atsc3CapableTuners(modelNumber: "hdfx-4k") == [0, 1])
        #expect(TunerModelTable.atsc3CapableTuners(modelNumber: "HDHR5-4US") == nil)
    }
}
