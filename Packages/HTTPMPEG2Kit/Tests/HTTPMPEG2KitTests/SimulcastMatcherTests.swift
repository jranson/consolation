@testable import HTTPMPEG2Kit
import Testing

/// Each ATSC 3.0 channel's ATSC 1.0 simulcast, on the rewritten `?show=all&tuning` capture.
struct SimulcastMatcherTests {
    @Test func mapsTheFixtureLikeTheVerifiedRule() throws {
        let lineup = try Fixture.lineup("lineup_show-all_tuning")
        let matches = SimulcastMatcher.simulcasts(in: lineup)
        #expect(matches["102.1"] == "2.1")
        #expect(matches["107.1"] == "7.1")
        #expect(matches["109.1"] == "9.1")
        #expect(matches["131.1"] == "31.1")
        #expect(matches["117.1"] == nil)
    }

    @Test func normalizesCallSignSuffixes() {
        #expect(SimulcastMatcher.normalized("KUSA-HD") == "KUSA")
        #expect(SimulcastMatcher.normalized("kdvr-dt") == "KDVR")
        #expect(SimulcastMatcher.normalized("KXDP-LD") == "KXDP")
        #expect(SimulcastMatcher.normalized("Cozi") == "COZI")
    }
}
