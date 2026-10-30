import Foundation
import Synchronization
@testable import HTTPMPEG2Kit

/// A canned answer for one stub host.
struct StubResponse: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var chunks: [Data] = []
    /// False keeps the connection open after the chunks, like a live stream.
    var finishes = true
    /// False never sends a response at all.
    var responds = true
    /// A transport failure instead of a response.
    var failure: URLError.Code?
}

/// What a stub host saw.
struct StubRequest: Sendable {
    let method: String?
    let url: URL?
    let userAgent: String?
    let range: String?
}

/// Answers every request in-process, so no test touches the network. Each test registers its own
/// unique host (under the reserved `.test` domain), so tests can run in parallel.
final class StubURLProtocol: URLProtocol {
    private static let responses = Mutex<[String: StubResponse]>([:])
    private static let requests = Mutex<[String: [StubRequest]]>([:])
    private static let stops = Mutex<[String: Int]>([:])

    /// Registers a stub and returns its unique host.
    static func register(_ response: StubResponse) -> String {
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        responses.withLock { $0[host] = response }
        return host
    }

    static func requests(for host: String) -> [StubRequest] {
        requests.withLock { $0[host] ?? [] }
    }

    static func stopCount(for host: String) -> Int {
        stops.withLock { $0[host] ?? 0 }
    }

    /// A session configuration built like the production one, with this stub in front.
    static func install(in configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host() ?? ""
        let seen = StubRequest(
            method: request.httpMethod,
            url: request.url,
            userAgent: request.value(forHTTPHeaderField: "User-Agent"),
            range: request.value(forHTTPHeaderField: "Range")
        )
        Self.requests.withLock { $0[host, default: []].append(seen) }
        guard let stub = Self.responses.withLock({ $0[host] }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        if let failure = stub.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        guard stub.responds else { return }
        guard let response = HTTPURLResponse(
            url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers
        ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in stub.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        if stub.finishes {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        let host = request.url?.host() ?? ""
        Self.stops.withLock { $0[host, default: 0] += 1 }
    }
}

extension HDHomeRunClient {
    /// A client whose requests are answered by `StubURLProtocol`.
    static func stubbed(host: String, configuration: TunerClientConfiguration = .testing) throws -> HDHomeRunClient {
        guard let baseURL = TunerHost.baseURL(for: host) else { throw HDHomeRunClientError.invalidHost(host) }
        let sessionConfiguration = StubURLProtocol.install(in: configuration.makeJSONSessionConfiguration())
        return HDHomeRunClient(
            baseURL: baseURL, configuration: configuration, sessionConfiguration: sessionConfiguration)
    }
}

extension HDHomeRunStreamClient {
    /// A stream whose single GET is answered by `StubURLProtocol`.
    static func stubbed(host: String, path: String = "/auto/v7.1") -> HDHomeRunStreamClient {
        let configuration = TunerClientConfiguration.testing
        let sessionConfiguration = StubURLProtocol.install(in: configuration.makeStreamSessionConfiguration())
        let url = URL(string: "http://\(host):5004\(path)") ?? URL(fileURLWithPath: "/")
        return HDHomeRunStreamClient(url: url, configuration: configuration, sessionConfiguration: sessionConfiguration)
    }
}

extension TunerClientConfiguration {
    static let testing = TunerClientConfiguration(
        userAgent: "HTTPMPEG2KitTests/1.0",
        requestTimeout: .seconds(5),
        resourceTimeout: .seconds(10),
        waitsForConnectivity: false,
        streamTimeout: .seconds(5)
    )
}
