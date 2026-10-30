import Foundation
import Testing
@testable import HTTPMPEG2Kit

@Suite("status.json and lineup_status.json decoding")
struct StatusDecodingTests {
    @Test func idleTunersAreAllFree() throws {
        let tuners = try Fixture.tunerStatus("status_idle")
        #expect(tuners.map(\.resource) == ["tuner0", "tuner1", "tuner2", "tuner3"])
        #expect(tuners.compactMap(\.tunerIndex) == [0, 1, 2, 3])
        #expect(tuners.allSatisfy { !$0.isInUse })
    }

    @Test func twoTunersInUse() throws {
        let tuners = try Fixture.tunerStatus("status_two-in-use")
        #expect(tuners.filter { !$0.isInUse }.map(\.resource) == ["tuner0", "tuner1"])

        let household = try #require(tuners.first { $0.resource == "tuner2" })
        #expect(household.isInUse)
        #expect(household.vctNumber == "7.1")
        #expect(household.vctName == "KMGH")
        #expect(household.frequency == 177_000_000)
        #expect(household.targetIP == "192.0.2.44")
        #expect(household.signalStrengthPercent == 48)
        #expect(household.signalQualityPercent == 55)
        #expect(household.symbolQualityPercent == 100)
        #expect(household.networkRate == 4_730_400)

        let ours = try #require(tuners.first { $0.resource == "tuner3" })
        #expect(ours.vctNumber == "31.1")
        #expect(ours.frequency == 605_000_000)
        #expect(ours.targetIP == "192.0.2.30")
    }

    @Test func aMultiplexTuneWithoutVctNumberIsInUse() throws {
        let tuners = try Fixture.tunerStatus("status_multiplex")
        let multiplex = try #require(tuners.first { $0.resource == "tuner0" })
        #expect(multiplex.vctNumber == nil)
        #expect(multiplex.frequency == 605_000_000)
        #expect(multiplex.isInUse)
        #expect(tuners.filter { !$0.isInUse }.map(\.resource) == ["tuner1", "tuner3"])
    }

    @Test func toleratesQuirkyEntries() throws {
        let tuners = try Fixture.tunerStatus("status_quirks")
        // The entry without Resource and the string are dropped.
        #expect(tuners.map(\.resource) == ["tuner0", "tuner1", "tuner2", "tuner3"])
        #expect(tuners.filter(\.isInUse).map(\.resource) == ["tuner0", "tuner2", "tuner3"])
        #expect(tuners[0].targetIP == "[2001:db8::30]")
        #expect(tuners[1].vctNumber == nil && tuners[1].targetIP == nil)   // empty strings read as absent
        #expect(tuners[2].vctNumber == "9.1")
        #expect(tuners[2].signalStrengthPercent == 54)
        #expect(tuners[3].frequency == 605_000_000)
    }

    @Test func inUseRuleChecksAllThreeKeys() {
        #expect(!TunerStatus(resource: "tuner0").isInUse)
        #expect(TunerStatus(resource: "tuner0", vctNumber: "7.1").isInUse)
        #expect(TunerStatus(resource: "tuner0", frequency: 605_000_000).isInUse)
        #expect(TunerStatus(resource: "tuner0", targetIP: "192.0.2.30").isInUse)
        #expect(!TunerStatus(resource: "tuner0", vctName: "KMGH", signalStrengthPercent: 50).isInUse)
        #expect(TunerStatus(resource: "tuner12").tunerIndex == 12)
        #expect(TunerStatus(resource: "storage").tunerIndex == nil)
    }

    @Test func statusEncodingRoundTrips() throws {
        let tuners = try Fixture.tunerStatus("status_two-in-use")
        #expect(try TunerJSON.tunerStatus(from: JSONEncoder().encode(tuners)) == tuners)
    }

    @Test func lineupStatusIdle() throws {
        let status = try TunerJSON.lineupStatus(from: Fixture.data("lineup_status"))
        #expect(status.source == "Antenna")
        #expect(status.sourceList == ["Antenna", "Cable"])
        #expect(!status.scanInProgress)
        #expect(status.scanPossible)
        #expect(status.progress == nil && status.found == nil)
        #expect(try TunerJSON.lineupStatus(from: JSONEncoder().encode(status)) == status)
    }

    @Test func lineupStatusScanning() throws {
        let status = try TunerJSON.lineupStatus(from: Fixture.data("lineup_status_scanning"))
        #expect(status.scanInProgress)
        #expect(status.source == "Cable")
        #expect(status.sourceList == ["Antenna", "Cable"])   // the non-string entry is skipped
        #expect(status.progress == 42)
        #expect(status.found == 17)
    }
}
