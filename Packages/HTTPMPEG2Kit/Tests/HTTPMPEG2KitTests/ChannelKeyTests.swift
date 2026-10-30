import Foundation
import Testing
@testable import HTTPMPEG2Kit

@Suite("ChannelKey and guide-number order")
struct ChannelKeyTests {
    @Test func stringFormRoundTrips() throws {
        let key = ChannelKey(source: "Antenna", guideNumber: "9.1")
        #expect(key.stringValue == "tvch:Antenna:9.1")
        #expect(key.description == "tvch:Antenna:9.1")
        #expect(ChannelKey(stringValue: key.stringValue) == key)

        let cable = try #require(ChannelKey(stringValue: "tvch:Cable:702"))
        #expect(cable.source == "Cable")
        #expect(cable.guideNumber == "702")

        // The last colon separates the guide number, so a colon in the source survives.
        let odd = ChannelKey(source: "Over:Air", guideNumber: "7.1")
        #expect(ChannelKey(stringValue: odd.stringValue) == odd)
    }

    @Test(arguments: ["", "tvch", "tvch:", "tvch:Antenna", "tvch::7.1", "tvch:Antenna:", "chan:Antenna:7.1",
                      "TVCH:Antenna:7.1", "hdhr:1234ABC2"])
    func rejectsMalformedStrings(string: String) {
        #expect(ChannelKey(stringValue: string) == nil)
    }

    @Test func encodesAsItsStringForm() throws {
        let key = ChannelKey(source: "Antenna", guideNumber: "9.1")
        let data = try JSONEncoder().encode([key])
        #expect(String(data: data, encoding: .utf8) == #"["tvch:Antenna:9.1"]"#)
        #expect(try JSONDecoder().decode([ChannelKey].self, from: data) == [key])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([ChannelKey].self, from: Data(#"["Antenna:9.1"]"#.utf8))
        }
    }

    @Test func neverContainsDeviceIdentity() throws {
        let channel = try Fixture.channel("7.1", in: Fixture.lineup("lineup"))
        let key = channel.channelKey(source: "Antenna")
        #expect(key.stringValue == "tvch:Antenna:7.1")
        #expect(!key.stringValue.localizedCaseInsensitiveContains(Fixture.deviceID))
        #expect(!key.stringValue.contains("local"))
    }

    @Test func sortsGuideNumbersNumerically() {
        let shuffled = ["31.1", "20.4", "2.1", "20.1", "4.1"]
        #expect(shuffled.sorted(by: GuideNumberOrder.areInIncreasingOrder) == ["2.1", "4.1", "20.1", "20.4", "31.1"])

        let mixed = ["7.10", "7.2", "7", "102.1", "7.1", "9-1", "abc", "8.5"]
        #expect(mixed.sorted(by: GuideNumberOrder.areInIncreasingOrder)
            == ["7", "7.1", "7.2", "7.10", "8.5", "9-1", "102.1", "abc"])
    }

    @Test func sortsChannelKeysBySourceThenNumber() {
        let keys = [
            ChannelKey(source: "Antenna", guideNumber: "31.1"),
            ChannelKey(source: "Cable", guideNumber: "2"),
            ChannelKey(source: "Antenna", guideNumber: "20.4"),
            ChannelKey(source: "Antenna", guideNumber: "2.1"),
            ChannelKey(source: "Antenna", guideNumber: "4.1"),
            ChannelKey(source: "Antenna", guideNumber: "20.1")
        ]
        #expect(keys.sorted().map(\.stringValue) == [
            "tvch:Antenna:2.1", "tvch:Antenna:4.1", "tvch:Antenna:20.1", "tvch:Antenna:20.4",
            "tvch:Antenna:31.1", "tvch:Cable:2"
        ])
    }

    @Test func parsesMajorAndMinor() {
        #expect(GuideNumberOrder.parts(of: "20.4")?.major == 20)
        #expect(GuideNumberOrder.parts(of: "20.4")?.minor == 4)
        #expect(GuideNumberOrder.parts(of: "7-1")?.minor == 1)
        #expect(GuideNumberOrder.parts(of: "702")?.major == 702)
        #expect(GuideNumberOrder.parts(of: "702")?.minor == nil)
        #expect(GuideNumberOrder.parts(of: "abc") == nil)
        #expect(GuideNumberOrder.parts(of: "7.") == nil)
        #expect(GuideNumberOrder.parts(of: "+7.1") == nil)
        #expect(GuideNumberOrder.parts(of: "99999999999999999999.1") == nil)
    }
}
