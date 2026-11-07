//
//  URLByteSourceTests.swift
//  PlaybackKitTests
//
//  Redirects between the two HTTP clients: an https URL answered with a redirect to plain http on a public address
//  (as IPTV servers do) must go on through the raw client, which URLSession can't reach under App Transport Security,
//  and the raw client's redirects go on through whichever client the target needs. A loopback server stands in for
//  both hosts; which hops count as "plain http off the local network" is decided by path.
//

import Foundation
import Network
import Testing
@testable import PlaybackKit

@Suite(.serialized)
struct URLByteSourceTests {
    private static func read(_ source: any ByteSource) async throws -> Data {
        var body = Data()
        for try await chunk in try await source.open() { body.append(chunk) }
        return body
    }

    @Test func urlSessionHandsARedirectToTheRawClient() async throws {
        let server = try await LoopbackHTTPServer { path in
            switch path {
            case "/live/1": .redirect("/raw/1?token=abc")
            case "/raw/1?token=abc": .chunked(["live ", "bytes"])
            default: .notFound
            }
        }
        defer { server.stop() }
        let source = URLByteSource(url: server.url("/live/1"), startingAt: 0, headers: [:],
                                   needsRawClient: { $0.path.hasPrefix("/raw/") })
        #expect(try await Self.read(source) == Data("live bytes".utf8))
        #expect(!source.isFinite, "chunked, so live")
        #expect(server.requests == ["/live/1", "/raw/1?token=abc"])
    }

    @Test func theRawClientsRedirectsGoThroughEitherClient() async throws {
        let server = try await LoopbackHTTPServer { path in
            switch path {
            case "/raw/start": .redirect("/raw/next")
            case "/raw/next": .redirect("/secure/file")
            case "/secure/file": .body("whole file")
            default: .notFound
            }
        }
        defer { server.stop() }
        let source = URLByteSource(url: server.url("/raw/start"), startingAt: 0, headers: [:],
                                   needsRawClient: { $0.path.hasPrefix("/raw/") })
        #expect(try await Self.read(source) == Data("whole file".utf8))
        #expect(source.isFinite && source.contentLength == 10)
        #expect(server.requests == ["/raw/start", "/raw/next", "/secure/file"])
    }

    @Test func aRedirectLoopEnds() async throws {
        let server = try await LoopbackHTTPServer { _ in .redirect("/raw/loop") }
        defer { server.stop() }
        let source = URLByteSource(url: server.url("/raw/loop"), startingAt: 0, headers: [:],
                                   needsRawClient: { _ in true })
        await #expect(throws: PlaybackError.self) { try await Self.read(source) }
        #expect(server.requests.count == URLByteSource.maximumRedirects + 1)
    }

    @Test func aSeekAsksTheOriginalURLAgain() async throws {
        let server = try await LoopbackHTTPServer { path in
            path == "/start" ? .redirect("/raw/data") : .body("0123456789")
        }
        defer { server.stop() }
        let source = URLByteSource(url: server.url("/start"), startingAt: 0, headers: [:],
                                   needsRawClient: { $0.path.hasPrefix("/raw/") })
        _ = try await Self.read(source)
        let reopened = try #require(source.reopened(at: 4))
        // The server ignores ranges: the client drops what comes before the offset.
        #expect(try await Self.read(reopened) == Data("456789".utf8))
        #expect(server.requests == ["/start", "/raw/data", "/start", "/raw/data"])
    }
}

/// A one-request-per-connection HTTP/1.1 server on 127.0.0.1 only, answering each request target with `route`.
nonisolated final class LoopbackHTTPServer: @unchecked Sendable {
    // @unchecked: `seen` is only touched under `lock`; the listener runs on `queue`.
    enum Response: Sendable {
        case body(String)
        case chunked([String])
        case redirect(String)
        case notFound

        var bytes: Data {
            switch self {
            case .body(let text):
                return Data(("HTTP/1.1 200 OK\r\nContent-Length: \(text.utf8.count)\r\nConnection: close\r\n\r\n" +
                             text).utf8)
            case .chunked(let pieces):
                let chunks = pieces.map { String($0.utf8.count, radix: 16) + "\r\n\($0)\r\n" }.joined()
                return Data(("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" +
                             chunks + "0\r\n\r\n").utf8)
            case .redirect(let location):
                return Data(("HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\n" +
                             "Connection: close\r\n\r\n").utf8)
            case .notFound:
                return Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            }
        }
    }

    private let listener: NWListener
    private let route: @Sendable (String) -> Response
    private let queue = DispatchQueue(label: "LoopbackHTTPServer")
    private let lock = NSLock()
    private var seen: [String] = []

    init(route: @escaping @Sendable (String) -> Response) async throws {
        let parameters = NWParameters.tcp
        // Loopback only: nothing listens on the network.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        self.route = route
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, any Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { ready.resume() }
                case .failed(let error): if once.take() { ready.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// The request targets served, in order.
    var requests: [String] { lock.withLock { seen } }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(listener.port?.rawValue ?? 0)\(path)")!
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
            guard let self, error == nil else { return connection.cancel() }
            let received = buffer + (data ?? Data())
            guard let head = String(bytes: received, encoding: .utf8), head.contains("\r\n\r\n") else {
                return done ? connection.cancel() : receive(on: connection, buffer: received)
            }
            let target = head.split(separator: " ", maxSplits: 2).dropFirst().first.map(String.init) ?? "/"
            lock.withLock { seen.append(target) }
            connection.send(content: route(target).bytes, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

/// True for the first `take()` only.
nonisolated private final class OnceFlag: @unchecked Sendable {
    // @unchecked: `taken` is only touched under `lock`.
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.withLock {
            defer { taken = true }
            return !taken
        }
    }
}
