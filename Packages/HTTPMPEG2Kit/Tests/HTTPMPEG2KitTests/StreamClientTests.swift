import Foundation
import Testing
@testable import HTTPMPEG2Kit

/// `HDHomeRunStreamClient` against `StubURLProtocol`: no request leaves the process.
@Suite("HDHomeRunStreamClient", .timeLimit(.minutes(1)))
struct StreamClientTests {
    private static let packets = [Data(repeating: 0x47, count: 188 * 7), Data(repeating: 0x47, count: 188 * 3)]

    private static func collect(_ stream: HDHomeRunStreamClient) async throws -> Data {
        var received = Data()
        for try await chunk in stream.chunks {
            received.append(chunk)
        }
        return received
    }

    /// Polls until `condition` holds or about two seconds pass.
    private static func eventually(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func opensWithOneGETAndDeliversTheBody() async throws {
        let host = StubURLProtocol.register(StubResponse(
            headers: ["Content-Type": "video/mpeg", "X-HDHomeRun-Resource": "tuner2"], chunks: Self.packets))
        let stream = HDHomeRunStreamClient.stubbed(host: host)
        let info = try await stream.open()
        #expect(info.resource == "tuner2")
        #expect(info.tunerIndex == 2)
        #expect(info.contentType == "video/mpeg")

        let received = try await Self.collect(stream)
        #expect(received.count == 188 * 10)

        let requests = StubURLProtocol.requests(for: host)
        #expect(requests.count == 1)
        #expect(requests.first?.method == "GET")
        #expect(requests.first?.range == nil)
        #expect(requests.first?.userAgent == "HTTPMPEG2KitTests/1.0")
        #expect(requests.first?.url?.absoluteString == "http://\(host):5004/auto/v7.1")
    }

    @Test(arguments: [
        ("805 All Tuners In Use", HDHomeRunClientError.allTunersInUse),
        ("811 Content Protection Required", .contentProtectionRequired),
        ("807 No Video Data", .noVideoData)
    ])
    func errorResponsesNeverDeliverTheBody(header: String, expected: HDHomeRunClientError) async throws {
        let host = StubURLProtocol.register(StubResponse(
            status: 503, headers: ["X-HDHomeRun-Error": header, "Content-Type": "text/html"],
            chunks: [Data("<html>error page that must not reach the demuxer</html>".utf8)]))
        let stream = HDHomeRunStreamClient.stubbed(host: host)
        await #expect(throws: expected) { try await stream.open() }

        var delivered = 0
        await #expect(throws: expected) {
            for try await chunk in stream.chunks {
                delivered += chunk.count
            }
        }
        #expect(delivered == 0)
        #expect(StubURLProtocol.requests(for: host).count == 1)
    }

    @Test func unknownChannelAndBare404() async throws {
        let unknown = StubURLProtocol.register(StubResponse(
            status: 404, headers: ["X-HDHomeRun-Error": "801 Unknown Channel"]))
        await #expect(throws: HDHomeRunClientError.unknownChannel) {
            try await HDHomeRunStreamClient.stubbed(host: unknown, path: "/auto/v999.9").open()
        }
        let bare = StubURLProtocol.register(StubResponse(status: 404))
        await #expect(throws: HDHomeRunClientError.http(status: 404, code: nil, message: nil)) {
            try await HDHomeRunStreamClient.stubbed(host: bare, path: "/tuner7/v7.1").open()
        }
        let redirect = StubURLProtocol.register(StubResponse(status: 302, headers: ["Location": "http://192.0.2.99/"]))
        await #expect(throws: HDHomeRunClientError.http(status: 302, code: nil, message: nil)) {
            try await HDHomeRunStreamClient.stubbed(host: redirect).open()
        }
    }

    @Test func concurrentOpensShareTheSingleGET() async throws {
        let host = StubURLProtocol.register(StubResponse(
            headers: ["X-HDHomeRun-Resource": "tuner3"], chunks: Self.packets, finishes: false))
        let stream = HDHomeRunStreamClient.stubbed(host: host)
        async let first = stream.open()
        async let second = stream.open()
        let results = try await [first, second]
        #expect(results.allSatisfy { $0.resource == "tuner3" })
        #expect(try await stream.open().resource == "tuner3")
        #expect(StubURLProtocol.requests(for: host).count == 1)
        stream.cancel()
    }

    @Test func cancelClosesTheConnectionAndEndsTheChunks() async throws {
        let host = StubURLProtocol.register(StubResponse(
            headers: ["X-HDHomeRun-Resource": "tuner1"], chunks: Self.packets, finishes: false))
        let stream = HDHomeRunStreamClient.stubbed(host: host)
        _ = try await stream.open()

        // URLSession may coalesce the stub's chunks, so count bytes rather than chunks.
        var iterator = stream.chunks.makeAsyncIterator()
        var received = try await iterator.next()?.count ?? 0
        #expect(received > 0)

        stream.cancel()
        stream.cancel()   // idempotent
        while let chunk = try await iterator.next() {
            received += chunk.count
        }
        #expect(received <= 188 * 10)
        #expect(try await Self.eventually { StubURLProtocol.stopCount(for: host) == 1 })
        await #expect(throws: HDHomeRunClientError.cancelled) { try await stream.open() }
        #expect(StubURLProtocol.requests(for: host).count == 1)
    }

    @Test func cancelBeforeOpenSendsNothing() async throws {
        let host = StubURLProtocol.register(StubResponse(chunks: Self.packets))
        let stream = HDHomeRunStreamClient.stubbed(host: host)
        stream.cancel()
        await #expect(throws: HDHomeRunClientError.cancelled) { try await stream.open() }
        #expect(try await Self.collect(stream).isEmpty)
        #expect(StubURLProtocol.requests(for: host).isEmpty)
    }

    @Test func cancellingTheOpeningTaskCancelsTheStream() async throws {
        let host = StubURLProtocol.register(StubResponse(responds: false))
        let stream = HDHomeRunStreamClient.stubbed(host: host)
        let opening = Task { try await stream.open() }
        #expect(try await Self.eventually { StubURLProtocol.requests(for: host).count == 1 })
        opening.cancel()
        await #expect(throws: HDHomeRunClientError.cancelled) { try await opening.value }
        #expect(try await Self.eventually { StubURLProtocol.stopCount(for: host) == 1 })
    }

    @Test func unreachableHostFailsOpen() async throws {
        let host = StubURLProtocol.register(StubResponse(failure: .timedOut))
        let stream = HDHomeRunStreamClient.stubbed(host: host)
        await #expect(throws: HDHomeRunClientError.unreachable(host: host, reason: .timedOut)) {
            try await stream.open()
        }
    }

    @Test func endingIterationCancelsTheRequest() async throws {
        let host = StubURLProtocol.register(StubResponse(
            headers: ["X-HDHomeRun-Resource": "tuner0"], chunks: Self.packets, finishes: false))
        let stream = HDHomeRunStreamClient.stubbed(host: host)
        _ = try await stream.open()
        let reader = Task {
            for try await _ in stream.chunks {}
        }
        try await Task.sleep(for: .milliseconds(50))
        reader.cancel()
        _ = await reader.result
        #expect(try await Self.eventually { StubURLProtocol.stopCount(for: host) == 1 })
        await #expect(throws: HDHomeRunClientError.cancelled) { try await stream.open() }
    }
}
