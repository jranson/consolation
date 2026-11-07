//
//  StreamKindCache.swift
//  Consolation
//
//  What the URLs whose path names no container stream (IPTV and relay URLs like `/user/token/1234`), learned from
//  their first bytes before an engine is made for them: raw MPEG-TS and Matroska never go to AVPlayer, so the engine
//  depends on it. Each URL is probed once per run; a probe that fails is tried again the next time.
//

import Foundation
import PlaybackKit

final class StreamKindCache {
    /// Kinds kept before the cache starts over.
    static let capacity = 256

    private var kinds: [URL: URLKind] = [:]
    private let probe: @Sendable (URL) async -> URLKind?

    init(probe: @escaping @Sendable (URL) async -> URLKind? = { await StreamSniffer.probe($0) }) {
        self.probe = probe
    }

    /// The kind to make an engine for: what the URL's path says, else what its bytes said, else `.unknown`.
    func kind(for url: URL) -> URLKind {
        let detected = URLKindDetector.detect(url)
        return detected == .unknown ? kinds[url] ?? .unknown : detected
    }

    /// An http(s) URL whose path names no container and that hasn't been probed.
    func needsProbe(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return URLKindDetector.detect(url) == .unknown && kinds[url] == nil
    }

    /// Reads the stream's first bytes, when `needsProbe`. Bytes no engine recognizes are left to AVPlayer and
    /// probed again next time.
    func learn(_ url: URL) async {
        guard needsProbe(url), let kind = await probe(url), kind != .unknown else { return }
        if kinds.count >= Self.capacity { kinds.removeAll() }
        kinds[url] = kind
    }
}
