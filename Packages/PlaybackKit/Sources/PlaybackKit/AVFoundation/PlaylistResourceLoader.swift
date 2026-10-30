//
//  PlaylistResourceLoader.swift
//  PlaybackKit
//
//  Serves generated or repaired HLS playlists to AVPlayer on a private URL scheme. Only playlists go through it: every
//  init and media segment URL inside them is an absolute http(s) URL that AVPlayer fetches itself (segment loads
//  through a custom scheme reportedly fail with -12881). AVFoundation calls the delegate on the loader's own queue, so
//  the class is nonisolated and its state sits behind a Mutex.
//
//  Custom-scheme assets reportedly can't AirPlay video, so engines use this only when they must.
//

import AVFoundation
import Foundation
import Synchronization

public nonisolated final class PlaylistResourceLoader: NSObject, AVAssetResourceLoaderDelegate, Sendable {
    /// The UTI AVFoundation expects for HLS playlists.
    static let playlistContentType = "public.m3u-playlist"

    /// The URL scheme, injected by the host so the package carries no branding.
    public let scheme: String
    /// A random host per loader, so a stale asset can never read another loader's playlists.
    public let host: String
    /// The queue AVFoundation calls the delegate on.
    public let queue: DispatchQueue

    private let playlists = Mutex<[String: Data]>([:])
    private let requestCount = Mutex(0)

    public init(scheme: String) {
        self.scheme = scheme.lowercased()
        self.host = UUID().uuidString.lowercased()
        self.queue = DispatchQueue(label: "PlaybackKit.PlaylistResourceLoader", qos: .userInitiated)
        super.init()
    }

    /// The URL AVPlayer should open for the playlist served under `name`.
    public func url(for name: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + name
        return components.url
    }

    /// Publishes (or replaces) a playlist.
    public func setPlaylist(_ text: String, named name: String) {
        playlists.withLock { $0[name] = Data(text.utf8) }
    }

    /// Publishes the multivariant playlist and every media playlist of `presentation`.
    public func publish(_ presentation: HLSPresentation) {
        playlists.withLock { stored in
            stored[HLSPresentation.multivariantName] = Data(presentation.multivariantPlaylist.utf8)
            for (name, text) in presentation.mediaPlaylists {
                stored[name] = Data(text.utf8)
            }
        }
    }

    public func removeAll() {
        playlists.withLock { $0.removeAll() }
    }

    /// How many loading requests have been answered, for diagnostics and tests.
    public var answeredRequests: Int {
        requestCount.withLock { $0 }
    }

    /// Makes this loader the asset's resource-loader delegate.
    public func attach(to asset: AVURLAsset) {
        asset.resourceLoader.setDelegate(self, queue: queue)
    }

    /// The stored playlist for `url`, or nil when the URL isn't one of this loader's.
    func playlistData(for url: URL) -> Data? {
        guard url.scheme?.lowercased() == scheme, url.host()?.lowercased() == host else { return nil }
        let name = String(url.path(percentEncoded: false).drop { $0 == "/" })
        return playlists.withLock { $0[name] }
    }

    // MARK: AVAssetResourceLoaderDelegate

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest)
        -> Bool {
        guard let url = loadingRequest.request.url, url.scheme?.lowercased() == scheme else { return false }
        guard let data = playlistData(for: url) else {
            loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
            return true
        }
        requestCount.withLock { $0 += 1 }
        if let information = loadingRequest.contentInformationRequest {
            information.contentType = Self.playlistContentType
            information.contentLength = Int64(data.count)
            information.isByteRangeAccessSupported = false
        }
        if let dataRequest = loadingRequest.dataRequest {
            let start = Int(clamping: max(0, min(dataRequest.requestedOffset, Int64(data.count))))
            let length = max(0, dataRequest.requestedLength)
            let end = dataRequest.requestsAllDataToEndOfResource || length >= data.count - start
                ? data.count : start + length
            dataRequest.respond(with: data.subdata(in: start..<end))
        }
        loadingRequest.finishLoading()
        return true
    }
}
