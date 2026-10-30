import Foundation
import Testing
@testable import HTTPMPEG2Kit

/// Truncated, non-JSON and hostile payloads must throw `HDHomeRunClientError.decoding`, never trap.
@Suite("Malformed input")
struct MalformedInputTests {
    /// Runs every public decoder over `data`. Returns the errors thrown (success is allowed for the
    /// rare random payload that happens to be valid JSON of the right shape).
    private static func decodeWithEveryDecoder(_ data: Data) -> [HDHomeRunClientError] {
        var errors: [HDHomeRunClientError] = []
        do { _ = try TunerJSON.discovery(from: data) } catch { errors.append(error) }
        do { _ = try TunerJSON.lineup(from: data) } catch { errors.append(error) }
        do { _ = try TunerJSON.tunerStatus(from: data) } catch { errors.append(error) }
        do { _ = try TunerJSON.lineupStatus(from: data) } catch { errors.append(error) }
        return errors
    }

    private static func isDecodingError(_ error: HDHomeRunClientError) -> Bool {
        if case .decoding = error { return true }
        return false
    }

    @Test func randomBytesThrowDecodingErrors() {
        var generator = SplitMix64(seed: 0x4844_4852)
        for _ in 0..<300 {
            let length = Int.random(in: 0...2_048, using: &generator)
            let bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
            let errors = Self.decodeWithEveryDecoder(Data(bytes))
            #expect(errors.allSatisfy(Self.isDecodingError))
        }
    }

    @Test(arguments: ["lineup", "lineup_show-all_tuning", "discover", "status_two-in-use", "lineup_status"])
    func truncatedPayloadsThrow(fixture: String) throws {
        let data = try Fixture.data(fixture)
        // Every fixture ends with a closing bracket and a newline; dropping the bracket breaks the JSON.
        for length in stride(from: 0, to: data.count - 2, by: 5) {
            let errors = Self.decodeWithEveryDecoder(data.prefix(length))
            #expect(errors.count == 4)
            #expect(errors.allSatisfy(Self.isDecodingError))
        }
    }

    @Test(arguments: ["", "null", "[]", "{}", "\"text\"", "42", "true", "<html>503</html>", "{\"GuideNumber\":"])
    func wrongTopLevelShapesThrowOrDecodeEmpty(payload: String) {
        let data = Data(payload.utf8)
        #expect(throws: HDHomeRunClientError.self) { try TunerJSON.discovery(from: data) }
        if payload == "[]" {
            #expect(throws: Never.self) { try TunerJSON.lineup(from: data) }
        } else {
            #expect(throws: HDHomeRunClientError.self) { try TunerJSON.lineup(from: data) }
            #expect(throws: HDHomeRunClientError.self) { try TunerJSON.tunerStatus(from: data) }
        }
    }

    @Test func deeplyNestedJSONThrows() {
        let data = Data(String(repeating: "[", count: 100_000).utf8)
        let errors = Self.decodeWithEveryDecoder(data)
        #expect(errors.count == 4)
        #expect(errors.allSatisfy(Self.isDecodingError))
    }

    @Test func invalidUTF8NeverTraps() {
        // [{"G\xFF\xFE":1}]: the parser may accept the key; the entry is unusable either way.
        let data = Data([0x5B, 0x7B, 0x22, 0x47, 0xFF, 0xFE, 0x22, 0x3A, 0x31, 0x7D, 0x5D])
        #expect(Self.decodeWithEveryDecoder(data).allSatisfy(Self.isDecodingError))
        #expect(((try? TunerJSON.lineup(from: data)) ?? []).isEmpty)
        #expect(Self.decodeWithEveryDecoder(Data([0x22, 0xC3, 0x28, 0x22])).count == 4)
    }

    @Test func oversizedNumbersReadAsAbsent() throws {
        let json = """
        [{"GuideNumber": "2.1", "Frequency": 99999999999999999999999, "ProgramNumber": -1e400,
          "SignalStrength": 1.5, "HD": 1e300}]
        """
        let channel = try #require(TunerJSON.lineup(from: Data(json.utf8)).first)
        #expect(channel.frequency == nil)
        #expect(channel.programNumber == nil)
        #expect(channel.signalStrength == nil)
        #expect(!channel.isHD)
    }

    @Test func decodingErrorsDescribeTheEndpointWithoutPayloadValues() {
        let secret = "do-not-log-this-value"
        let data = Data(#"{"DeviceID": "\#(secret)"}"#.utf8)
        do {
            _ = try TunerJSON.discovery(from: data)
            Issue.record("expected a decoding error")
        } catch {
            guard case .decoding(let detail) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(detail.hasPrefix("discover.json"))
            #expect(!detail.contains(secret))
        }
    }
}

/// A small deterministic generator so the random-bytes test is reproducible.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
