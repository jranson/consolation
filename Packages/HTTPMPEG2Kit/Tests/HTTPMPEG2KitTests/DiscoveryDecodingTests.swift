import Foundation
import Testing
@testable import HTTPMPEG2Kit

@Suite("discover.json decoding")
struct DiscoveryDecodingTests {
    @Test func decodesTheFlex4KCapture() throws {
        let discovery = try TunerJSON.discovery(from: Fixture.data("discover"))
        #expect(discovery.deviceID.rawValue == Fixture.deviceID)
        #expect(discovery.friendlyName == "HDHomeRun FLEX 4K")
        #expect(discovery.modelNumber == "HDFX-4K")
        #expect(discovery.firmwareName == "hdhomerun_dvr_atsc3")
        #expect(discovery.firmwareVersion == "20260326")
        #expect(discovery.tunerCount == 4)
        // BaseURL follows the Host used for the request (hdhomerun.local), so it is the device's mDNS name.
        #expect(discovery.baseURL?.absoluteString == "http://\(Fixture.hostname)")
        #expect(discovery.lineupURL?.absoluteString == "http://\(Fixture.hostname)/lineup.json")
        #expect(discovery.baseIPv4 == nil)
        #expect(discovery.storageID == nil)
        #expect(discovery.storageURL == nil)
    }

    @Test func ignoresDeviceAuthEverywhere() throws {
        let token = "synthetic-auth-value-0123456789"
        let json = """
        {"DeviceID": "1234ABC2", "DeviceAuth": "\(token)", "BaseURL": "http://192.0.2.10", "TunerCount": 4}
        """
        let discovery = try TunerJSON.discovery(from: Data(json.utf8))
        #expect(discovery.deviceID.rawValue == "1234ABC2")

        let encoded = try JSONEncoder().encode(discovery)
        let encodedText = try #require(String(data: encoded, encoding: .utf8))
        #expect(!encodedText.contains(token))
        #expect(!encodedText.localizedCaseInsensitiveContains("auth"))

        #expect(!String(describing: discovery).contains(token))
        #expect(!String(reflecting: discovery).contains(token))
        let labels = Mirror(reflecting: discovery).children.compactMap(\.label)
        #expect(!labels.contains { $0.localizedCaseInsensitiveContains("auth") })

        let record = TunerDeviceRecord(discovery: discovery, host: "192.0.2.10")
        let recordText = try #require(String(data: JSONEncoder().encode(record), encoding: .utf8))
        #expect(!recordText.contains(token))
        #expect(!recordText.localizedCaseInsensitiveContains("auth"))
    }

    @Test func decodesStorageKeysAndLenientValues() throws {
        let discovery = try TunerJSON.discovery(from: Fixture.data("discover_storage"))
        #expect(discovery.deviceID.rawValue == "1234ABC2")   // lowercase input is uppercased
        #expect(discovery.tunerCount == 4)                   // sent as the string "4"
        #expect(discovery.storageID == "1234ABC2-0000-0000-0000-000000000000")
        #expect(discovery.storageURL?.absoluteString == "http://192.0.2.10/recorded_files.json")
        #expect(discovery.baseIPv4 == "192.0.2.10")
    }

    @Test func encodingRoundTrips() throws {
        let discovery = try TunerJSON.discovery(from: Fixture.data("discover"))
        let decoded = try TunerJSON.discovery(from: JSONEncoder().encode(discovery))
        #expect(decoded == discovery)
    }

    @Test(arguments: [
        #"{"FriendlyName": "No ID"}"#,
        #"{"DeviceID": "XYZ"}"#,
        #"{"DeviceID": "1234ABC"}"#,
        #"{"DeviceID": ""}"#,
        #"{"DeviceID": ["1234ABC2"]}"#
    ])
    func rejectsAMissingOrMalformedDeviceID(json: String) {
        #expect(throws: HDHomeRunClientError.self) {
            try TunerJSON.discovery(from: Data(json.utf8))
        }
    }

    @Test func toleratesOversizedAndWrongTypedNumbers() throws {
        let json = #"{"DeviceID": "1234ABC2", "TunerCount": 1e400, "ModelNumber": 7, "BaseURL": 12}"#
        let discovery = try TunerJSON.discovery(from: Data(json.utf8))
        #expect(discovery.tunerCount == nil)
        #expect(discovery.modelNumber == "7")
        #expect(discovery.baseURL == nil)
    }

    @Test func deviceIDNormalizesAndValidates() throws {
        let deviceID = try #require(TunerDeviceID(rawValue: " 1234abc2 \n"))
        #expect(deviceID.rawValue == "1234ABC2")
        #expect(deviceID.description == "1234ABC2")
        #expect(deviceID.hostname == "hdhr-1234abc2.local")
        #expect(TunerDeviceID(rawValue: "1234ABCG") == nil)
        #expect(TunerDeviceID(rawValue: "1234ABC22") == nil)
        #expect(TunerDeviceID(rawValue: "") == nil)
    }
}
