import Foundation
import Testing
@testable import HTTPMPEG2Kit

/// The verified free-tuner rule: a tuner is in use when it reports `VctNumber`, `Frequency` or `TargetIP`.
struct TunerCapacityTests {
    private static let statuses = [
        TunerStatus(resource: "tuner0"),
        TunerStatus(resource: "tuner1", vctNumber: "7.1", vctName: "KMGH", frequency: 605_000_000,
                    targetIP: "192.0.2.44"),
        // A full-multiplex tune: Frequency and TargetIP, no VctNumber.
        TunerStatus(resource: "tuner2", frequency: 473_000_000, targetIP: "192.0.2.30"),
        TunerStatus(resource: "tuner3", vctNumber: "9.1", targetIP: "192.0.2.20"),
        // A name and a signal reading alone do not make a tuner busy.
        TunerStatus(resource: "tuner4", vctName: "KUSA", signalStrengthPercent: 80)
    ]

    @Test func splitsFreeOursAndOthers() {
        let capacity = TunerCapacity(statuses: Self.statuses, ourResources: ["TUNER3"])
        #expect(capacity.total == 5)
        #expect(capacity.free.map(\.resource) == ["tuner0", "tuner4"])
        #expect(capacity.ours.map(\.resource) == ["tuner3"])
        #expect(capacity.others.map(\.resource) == ["tuner1", "tuner2"])
    }

    @Test func targetIPIsTheFallbackForOurs() {
        let capacity = TunerCapacity(statuses: Self.statuses, ourAddresses: ["192.0.2.30"])
        #expect(capacity.ours.map(\.resource) == ["tuner2"])
        #expect(capacity.others.map(\.resource) == ["tuner1", "tuner3"])
    }

    @Test func eachOfTheThreeKeysAloneMeansInUse() {
        let single = [
            TunerStatus(resource: "tuner0", vctNumber: "2.1"),
            TunerStatus(resource: "tuner1", frequency: 605_000_000),
            TunerStatus(resource: "tuner2", targetIP: "[fe80::1]"),
            TunerStatus(resource: "tuner3")
        ]
        let capacity = TunerCapacity(statuses: single)
        #expect(capacity.free.map(\.resource) == ["tuner3"])
        #expect(capacity.others.count == 3)
    }

    @Test func availableCountsOnlyOurOwnTunersBeingReleased() {
        let capacity = TunerCapacity(statuses: Self.statuses, ourResources: ["tuner3"])
        #expect(capacity.available() == 2)
        #expect(capacity.available(releasing: 1) == 3)
        #expect(capacity.available(releasing: 5) == 3)
        #expect(TunerCapacity(statuses: Self.statuses).available(releasing: 1) == 2)
    }

    @Test func purposesNeedFreeTunersAfterTheReserve() {
        #expect(TunePurpose.watch.requiredFreeTuners(reserve: 1) == nil)
        #expect(TunePurpose.tile.requiredFreeTuners(reserve: 1) == 2)
        #expect(TunePurpose.tile.requiredFreeTuners(reserve: -3) == 1)
        #expect(TunePurpose.guideHarvest.requiredFreeTuners(reserve: 1) == 3)
    }
}
