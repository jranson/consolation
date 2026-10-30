import Foundation
import Network
import Synchronization

/// A minimal HTTP client for relay tests, over loopback only. A reading client collects everything the server
/// sends; a non-reading one never drains its socket, like a client on a network too slow for the stream.
nonisolated final class RelayTestClient: Sendable {
    private struct State {
        var received = Data()
        var isClosed = false
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "RelayTestClient")
    private let reads: Bool
    private let state = Mutex(State())

    init(port: UInt16, reads: Bool = true) {
        self.reads = reads
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .http, using: .tcp)
    }

    /// Everything received so far, head included.
    var received: Data { state.withLock { $0.received } }
    /// True once the server closed the connection.
    var isClosed: Bool { state.withLock { $0.isClosed } }

    /// The response head, once it arrived.
    var head: String? {
        let data = received
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        return String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8)
    }

    /// The body bytes received so far.
    var body: Data {
        let data = received
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else { return Data() }
        return Data(data[end.upperBound...])
    }

    func send(_ request: String) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.state.withLock { $0.isClosed = true }
            default: break
            }
        }
        connection.start(queue: queue)
        connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
        if reads { receive() }
    }

    func get(_ path: String) {
        send("GET \(path) HTTP/1.1\r\nHost: relay\r\n\r\n")
    }

    func cancel() {
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isDone, error in
            guard let self else { return }
            state.withLock { state in
                if let data { state.received.append(data) }
                if isDone || error != nil { state.isClosed = true }
            }
            if !isDone && error == nil { receive() }
        }
    }
}

/// Polls until `condition` holds or about `seconds` pass.
nonisolated func eventually(seconds: Double = 5, _ condition: () async -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1_000))
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
