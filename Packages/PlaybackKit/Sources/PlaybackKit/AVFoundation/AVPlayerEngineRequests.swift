//
//  AVPlayerEngineRequests.swift
//  PlaybackKit
//
//  The engine's requests: the assets AVPlayer loads and the session that fetches playlists and manifests, both
//  carrying the host's request headers (a server's token), so a secret never has to go in a URL.
//

import AVFoundation
import Foundation

extension AVPlayerEngine {
    /// AVURLAsset's option for headers on every request the asset makes (playlists, segments and byte ranges).
    /// It has no public constant, but its name is stable and widely used; the public alternative, a resource loader
    /// for every request, can't serve HLS segments.
    nonisolated static let httpHeaderFieldsOption = "AVURLAssetHTTPHeaderFieldsKey"

    /// An asset for `url`, served by the loader when it is one of the loader's, with the request headers.
    func makeAsset(_ url: URL) -> AVURLAsset {
        let options: [String: Any] = requestHeaders.isEmpty ? [:] : [Self.httpHeaderFieldsOption: requestHeaders]
        let asset = AVURLAsset(url: url, options: options)
        if let loader, url.scheme?.lowercased() == loader.scheme {
            loader.attach(to: asset)
        }
        return asset
    }

    /// The fetcher for manifests, playlists and probes, over one ephemeral session that sends the request headers.
    func makeFetcher() -> URLSessionMediaFetcher {
        if let session {
            return URLSessionMediaFetcher(session: session)
        }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 15
        sessionConfiguration.waitsForConnectivity = false
        sessionConfiguration.urlCache = nil
        if !requestHeaders.isEmpty {
            sessionConfiguration.httpAdditionalHeaders = requestHeaders
        }
        let session = URLSession(configuration: sessionConfiguration)
        self.session = session
        return URLSessionMediaFetcher(session: session)
    }
}
