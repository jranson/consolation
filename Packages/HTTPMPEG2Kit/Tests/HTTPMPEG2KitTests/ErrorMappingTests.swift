import Foundation
import Testing
@testable import HTTPMPEG2Kit

@Suite("HDHomeRunClientError mapping")
struct ErrorMappingTests {
    static let deviceErrors: [(header: String, error: HDHomeRunClientError)] = [
        ("801 Unknown Channel", .unknownChannel),
        ("802 Unknown Transcode Profile", .unknownTranscodeProfile),
        ("803 System Busy", .systemBusy),
        ("804 Tuner In Use", .tunerInUse),
        ("805 All Tuners In Use", .allTunersInUse),
        ("806 Tune Failed", .tuneFailed),
        ("807 No Video Data", .noVideoData),
        ("808 DVR Failure", .dvrFailure),
        ("809 DVR Playback Limit", .playbackConnectionLimit),
        ("810 DVR Full", .dvrFull),
        ("811 Content Protection Required", .contentProtectionRequired)
    ]

    @Test(arguments: zip(deviceErrors.map(\.header), deviceErrors.map(\.error)))
    func mapsEveryDeviceErrorCode(header: String, expected: HDHomeRunClientError) throws {
        #expect(HDHomeRunClientError(status: 503, errorHeader: header) == expected)
        // The code decides, whatever the status.
        #expect(HDHomeRunClientError(status: 404, errorHeader: header) == expected)
        let code = try #require(Int(header.prefix(3)))
        #expect(expected.code == code)
        #expect(HDHomeRunClientError.deviceError(code: code) == expected)
        #expect(!expected.message.isEmpty)
    }

    @Test func coversTheWholeRange() {
        let codes = Array(HDHomeRunClientError.deviceErrorCodes)
        #expect(Self.deviceErrors.compactMap(\.error.code) == codes)
        #expect(Self.deviceErrors.compactMap { Int($0.header.prefix(3)) } == codes)
        #expect(Set(Self.deviceErrors.map(\.error)).count == 11)
    }

    @Test func observedHeaders() {
        #expect(HDHomeRunClientError(status: 404, errorHeader: "801 Unknown Channel") == .unknownChannel)
        #expect(HDHomeRunClientError(status: 503, errorHeader: "811 Content Protection Required")
            == .contentProtectionRequired)
        #expect(HDHomeRunClientError(status: 503, errorHeader: "  805   All Tuners In Use \r\n") == .allTunersInUse)
        #expect(HDHomeRunClientError(status: 503, errorHeader: "805") == .allTunersInUse)
    }

    @Test func otherResponsesBecomeHTTPErrors() {
        #expect(HDHomeRunClientError(status: 404, errorHeader: nil) == .http(status: 404, code: nil, message: nil))
        #expect(HDHomeRunClientError(status: 404, errorHeader: "") == .http(status: 404, code: nil, message: nil))
        #expect(HDHomeRunClientError(status: 503, errorHeader: "Tuner Exploded")
            == .http(status: 503, code: nil, message: "Tuner Exploded"))
        #expect(HDHomeRunClientError(status: 503, errorHeader: "899 Future Error")
            == .http(status: 503, code: 899, message: "Future Error"))
        #expect(HDHomeRunClientError(status: 500, errorHeader: "99999999999999999999 Overflow")
            == .http(status: 500, code: nil, message: "99999999999999999999 Overflow"))
        #expect(HDHomeRunClientError.http(status: 503, code: 899, message: nil).code == 899)
        #expect(HDHomeRunClientError.unreachable(host: "192.0.2.10", reason: nil).code == nil)
    }

    @Test func parsesErrorHeaders() {
        let parsed = HDHomeRunClientError.parseErrorHeader("805 All Tuners In Use")
        #expect(parsed.code == 805)
        #expect(parsed.message == "All Tuners In Use")
        #expect(HDHomeRunClientError.parseErrorHeader(nil).code == nil)
        #expect(HDHomeRunClientError.parseErrorHeader("abc").message == "abc")
    }

    @Test func mapsTransportErrors() {
        let host = "192.0.2.10"
        #expect(HDHomeRunClientError(transportError: URLError(.timedOut), host: host)
            == .unreachable(host: host, reason: .timedOut))
        #expect(HDHomeRunClientError(transportError: URLError(.cannotFindHost), host: host)
            == .unreachable(host: host, reason: .cannotFindHost))
        #expect(HDHomeRunClientError(transportError: URLError(.cannotConnectToHost), host: host)
            == .unreachable(host: host, reason: .cannotConnectToHost))
        #expect(HDHomeRunClientError(transportError: URLError(.cancelled), host: host) == .cancelled)
        #expect(HDHomeRunClientError(transportError: CancellationError(), host: host) == .cancelled)
        #expect(HDHomeRunClientError(transportError: URLError(.badServerResponse), host: host) == .invalidResponse)
        #expect(HDHomeRunClientError(transportError: URLError(.unsupportedURL), host: host) == .invalidHost(host))
        #expect(HDHomeRunClientError(transportError: HDHomeRunClientError.allTunersInUse, host: host)
            == .allTunersInUse)
    }

    @Test func everyCaseHasAShortUserFacingMessage() {
        let deviceID = TunerDeviceID(rawValue: "1234ABC2")
        var errors = Self.deviceErrors.map(\.error)
        errors += [
            .http(status: 404, code: nil, message: nil),
            .http(status: 503, code: 899, message: "Future"),
            .invalidHost("bad host"),
            .unreachable(host: "192.0.2.27", reason: .timedOut),
            .connectionLost,
            .cancelled,
            .invalidResponse,
            .decoding("lineup.json: malformed data at top level"),
            .localNetworkUnavailable(errno: 1)
        ]
        if let deviceID {
            errors.append(.deviceMismatch(expected: deviceID, found: deviceID))
        }
        for error in errors {
            #expect(!error.message.isEmpty)
            #expect(error.message.count < 120)
            #expect(error.errorDescription == error.message)
            #expect(error.localizedDescription == error.message)
        }
        #expect(Set(errors.map(\.message)).count == errors.count)
        #expect(HDHomeRunClientError.unreachable(host: "192.0.2.27", reason: nil).message.contains("192.0.2.27"))
        #expect(HDHomeRunClientError.http(status: 404, code: nil, message: nil).message.contains("404"))
    }
}
