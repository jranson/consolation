import Foundation
import Testing
@testable import HTTPMPEG2Kit

/// `HDHomeRunClient` against `StubURLProtocol`: no request leaves the process.
@Suite("HDHomeRunClient", .timeLimit(.minutes(1)))
struct ClientTests {
    private static func stub(_ fixture: String) throws -> String {
        try StubURLProtocol.register(StubResponse(
            headers: ["Content-Type": "application/json"], chunks: [Fixture.data(fixture)]))
    }

    @Test func discoverSendsOneGET() async throws {
        let host = try Self.stub("discover")
        let client = try HDHomeRunClient.stubbed(host: host)
        let discovery = try await client.discover()
        #expect(discovery.deviceID.rawValue == Fixture.deviceID)

        let requests = StubURLProtocol.requests(for: host)
        #expect(requests.count == 1)
        #expect(requests.first?.method == "GET")
        #expect(requests.first?.url?.path() == "/discover.json")
        #expect(requests.first?.userAgent == "HTTPMPEG2KitTests/1.0")
    }

    @Test func discoverExpectingAnotherDeviceThrows() async throws {
        let host = try Self.stub("discover")
        let client = try HDHomeRunClient.stubbed(host: host)
        let expected = try #require(TunerDeviceID(rawValue: "ABCDEF01"))
        let found = try #require(TunerDeviceID(rawValue: Fixture.deviceID))
        await #expect(throws: HDHomeRunClientError.deviceMismatch(expected: expected, found: found)) {
            try await client.discover(expecting: expected)
        }
        #expect(try await client.discover(expecting: found).deviceID == found)
    }

    @Test func lineupDefaultsToTheVisibleList() async throws {
        let host = try Self.stub("lineup")
        let client = try HDHomeRunClient.stubbed(host: host)
        let channels = try await client.lineup()
        #expect(channels.count == 8)
        let url = try #require(StubURLProtocol.requests(for: host).first?.url)
        #expect(url.path() == "/lineup.json")
        #expect(url.query() == nil)
    }

    @Test func lineupShowAllWithTuning() async throws {
        let host = try Self.stub("lineup_show-all_tuning")
        let client = try HDHomeRunClient.stubbed(host: host)
        let channels = try await client.lineup(showAll: true, tuning: true)
        #expect(channels.count == 122)
        #expect(StubURLProtocol.requests(for: host).first?.url?.query() == "show=all&tuning")
    }

    @Test func statusAndLineupStatus() async throws {
        let statusHost = try Self.stub("status_two-in-use")
        let tuners = try await HDHomeRunClient.stubbed(host: statusHost).status()
        #expect(tuners.filter(\.isInUse).count == 2)

        let lineupHost = try Self.stub("lineup_status")
        let status = try await HDHomeRunClient.stubbed(host: lineupHost).lineupStatus()
        #expect(status.source == "Antenna")
        #expect(StubURLProtocol.requests(for: lineupHost).allSatisfy { $0.method == "GET" })
    }

    @Test func mapsHTTPErrors() async throws {
        let busy = StubURLProtocol.register(StubResponse(
            status: 503, headers: ["X-HDHomeRun-Error": "803 System Busy"], chunks: [Data("busy".utf8)]))
        await #expect(throws: HDHomeRunClientError.systemBusy) {
            try await HDHomeRunClient.stubbed(host: busy).lineup()
        }
        let missing = StubURLProtocol.register(StubResponse(status: 404))
        await #expect(throws: HDHomeRunClientError.http(status: 404, code: nil, message: nil)) {
            try await HDHomeRunClient.stubbed(host: missing).lineupStatus()
        }
    }

    @Test func mapsUnreadableBodies() async throws {
        let host = StubURLProtocol.register(StubResponse(chunks: [Data("<html>oops</html>".utf8)]))
        let client = try HDHomeRunClient.stubbed(host: host)
        do {
            _ = try await client.status()
            Issue.record("expected a decoding error")
        } catch {
            guard case .decoding = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }
    }

    @Test func mapsUnreachableHosts() async throws {
        let host = StubURLProtocol.register(StubResponse(failure: .cannotConnectToHost))
        await #expect(throws: HDHomeRunClientError.unreachable(host: host, reason: .cannotConnectToHost)) {
            try await HDHomeRunClient.stubbed(host: host).discover()
        }
    }

    @Test func sessionConfigurationIsEphemeralAndUncached() {
        let configuration = TunerClientConfiguration.testing.makeJSONSessionConfiguration()
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(configuration.timeoutIntervalForRequest == 5)

        let stream = TunerClientConfiguration.testing.makeStreamSessionConfiguration()
        #expect(stream.urlCache == nil)
        #expect(!stream.waitsForConnectivity)
        #expect(stream.timeoutIntervalForRequest == 5)
    }
}
