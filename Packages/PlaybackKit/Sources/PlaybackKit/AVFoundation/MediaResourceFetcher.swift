//
//  MediaResourceFetcher.swift
//  PlaybackKit
//
//  Small, size-capped GETs for manifests, playlists, init segments and segment heads. Only ever called for the
//  URL the user is playing and the resources its manifest references.
//

import Foundation

/// Fetches small resources. Injected so tests run without the network.
public nonisolated protocol MediaResourceFetching: Sendable {
    /// Returns at most `maxBytes`. With a `range`, a longer body is truncated (servers may ignore `Range`);
    /// without one, a longer body is an error.
    func fetch(_ url: URL, range: ClosedRange<Int>?, maxBytes: Int) async throws -> Data
}

/// `MediaResourceFetching` over a caller-owned `URLSession` (the engine uses an ephemeral one and invalidates it).
public nonisolated struct URLSessionMediaFetcher: MediaResourceFetching {
    public let session: URLSession
    public let timeout: TimeInterval

    public init(session: URLSession, timeout: TimeInterval = 15) {
        self.session = session
        self.timeout = timeout
    }

    public func fetch(_ url: URL, range: ClosedRange<Int>?, maxBytes: Int) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        if let range {
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        }
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw PlaybackErrorMapping.playbackError(from: error, title: "Can't reach the server")
        }
        defer { bytes.task.cancel() }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw PlaybackError(kind: .network, title: "The server refused the request",
                                detail: "HTTP status \(http.statusCode)", domain: PlaybackErrorMapping.httpDomain,
                                code: http.statusCode)
        }
        if range == nil, response.expectedContentLength > Int64(maxBytes) {
            throw PlaybackErrorMapping.tooLarge
        }
        var data = Data()
        data.reserveCapacity(min(maxBytes, max(0, Int(clamping: response.expectedContentLength))))
        do {
            for try await byte in bytes {
                if data.count >= maxBytes {
                    if range != nil { break }
                    throw PlaybackErrorMapping.tooLarge
                }
                data.append(byte)
            }
        } catch let error as PlaybackError {
            throw error
        } catch {
            throw PlaybackErrorMapping.playbackError(from: error, title: "The download was interrupted")
        }
        return data
    }
}
