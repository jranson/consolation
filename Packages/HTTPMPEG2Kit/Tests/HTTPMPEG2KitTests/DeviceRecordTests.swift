import Foundation
import Testing
@testable import HTTPMPEG2Kit

@Suite("TunerDeviceRecord")
struct DeviceRecordTests {
    @Test func recordFromAnMDNSHost() throws {
        let discovery = try TunerJSON.discovery(from: Fixture.data("discover"))
        let record = TunerDeviceRecord(discovery: discovery, host: "hdhomerun.local")
        #expect(record.deviceID.rawValue == Fixture.deviceID)
        #expect(record.id == record.deviceID)
        #expect(record.host == "hdhomerun.local")
        #expect(record.ipv4 == nil)
        #expect(record.hostname == Fixture.hostname)
        #expect(record.friendlyName == "HDHomeRun FLEX 4K")
        #expect(record.modelNumber == "HDFX-4K")
        #expect(record.tunerCount == 4)
    }

    @Test func recordKeepsTheHostAsEnteredAndItsIPv4() throws {
        let discovery = try TunerJSON.discovery(from: Fixture.data("discover"))
        let record = TunerDeviceRecord(discovery: discovery, host: "http://192.0.2.10/")
        #expect(record.host == "http://192.0.2.10/")
        #expect(record.ipv4 == "192.0.2.10")
    }

    @Test func recordTakesTheIPv4FromBaseURL() throws {
        let discovery = try TunerJSON.discovery(from: Fixture.data("discover_storage"))
        let record = TunerDeviceRecord(discovery: discovery, host: "hdhomerun.local")
        #expect(record.ipv4 == "192.0.2.10")
    }

    @Test func recordRoundTripsWithStableKeys() throws {
        let discovery = try TunerJSON.discovery(from: Fixture.data("discover"))
        let record = TunerDeviceRecord(discovery: discovery, host: "192.0.2.10")
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(TunerDeviceRecord.self, from: data) == record)

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["deviceID", "host", "ipv4", "hostname", "friendlyName", "modelNumber",
                                     "tunerCount"])
        #expect(object["deviceID"] as? String == Fixture.deviceID)
    }

    @Test func recordDecodesWithoutOptionalFields() throws {
        let json = #"{"deviceID": "1234ABC2", "host": "192.0.2.10", "hostname": "hdhr-1234abc2.local"}"#
        let record = try JSONDecoder().decode(TunerDeviceRecord.self, from: Data(json.utf8))
        #expect(record.ipv4 == nil)
        #expect(record.tunerCount == nil)
    }
}
