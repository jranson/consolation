//
//  URLKindDetector.swift
//  PlaybackKit
//
//  Classifies a user-supplied URL by its path extension, a few common query conventions and the HDHomeRun stream path,
//  without touching the network. When this says `.unknown`, Quick Play sniffs the first bytes of the real GET instead.
//

import Foundation

public nonisolated enum URLKind: String, Equatable, Sendable {
    case dash
    case hls
    case transportStream
    case progressive
    case unknown

    /// The AVPlayerEngine input for this kind, or nil when AVPlayer isn't the engine for it.
    public var avPlayerInputKind: AVPlayerEngine.InputKind? {
        switch self {
        case .dash: .dash
        case .hls: .hls
        case .progressive: .file
        case .transportStream, .unknown: nil
        }
    }
}

public nonisolated enum URLKindDetector {
    private static let extensionKinds: [String: URLKind] = [
        "mpd": .dash,
        "m3u8": .hls, "m3u": .hls,
        "ts": .transportStream, "m2ts": .transportStream, "mts": .transportStream,
        "mp4": .progressive, "mov": .progressive, "m4v": .progressive
    ]
    /// Query keys some servers use to name the container (`?format=m3u8`, `?output=ts`, `?type=mpd`).
    private static let formatQueryKeys: Set<String> = ["format", "output", "type", "ext", "container", "streamtype"]
    /// Query and Azure-style `(format=…)` values that name a container.
    private static let formatValueKinds: [String: URLKind] = [
        "mpd": .dash, "dash": .dash, "mpd-time-csf": .dash, "mpd-time-cmaf": .dash,
        "m3u8": .hls, "hls": .hls, "m3u8-aapl": .hls, "m3u8-cmaf": .hls,
        "ts": .transportStream, "mpegts": .transportStream, "mp2t": .transportStream,
        "mp4": .progressive, "mov": .progressive
    ]

    public static func detect(_ url: URL) -> URLKind {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        let path = components?.percentEncodedPath.removingPercentEncoding ?? url.path(percentEncoded: false)
        let segments = path.split(separator: "/").map(String.init)
        if let last = segments.last, let dot = last.lastIndex(of: ".") {
            let pathExtension = last[last.index(after: dot)...].lowercased()
            if let kind = extensionKinds[pathExtension] { return kind }
        }
        if let kind = azureFormat(segments.last) { return kind }
        for item in components?.queryItems ?? [] where formatQueryKeys.contains(item.name.lowercased()) {
            let value = (item.value ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if let kind = formatValueKinds[value] { return kind }
        }
        if isHDHomeRunStream(segments: segments, port: url.port) { return .transportStream }
        return .unknown
    }

    /// Azure Media Services style `…/manifest(format=m3u8-aapl)`.
    private static func azureFormat(_ segment: String?) -> URLKind? {
        guard let segment = segment?.lowercased(), let range = segment.range(of: "(format=") else { return nil }
        let value = segment[range.upperBound...].prefix { $0 != ")" && $0 != "," }
        return formatValueKinds[String(value)]
    }

    /// HDHomeRun's HTTP stream paths: `:5004/auto/v2.1`, `:5004/tuner0/v7.1` or `/tuner1/ch473000000`.
    private static func isHDHomeRunStream(segments: [String], port: Int?) -> Bool {
        guard let first = segments.first?.lowercased() else { return false }
        let isTunerPath = first == "auto"
            || (first.hasPrefix("tuner") && !first.dropFirst(5).isEmpty && first.dropFirst(5).allSatisfy(\.isNumber))
        guard isTunerPath else { return false }
        if port == 5004 { return true }
        guard segments.count >= 2 else { return false }
        let channel = segments[1].lowercased()
        return channel.hasPrefix("v") || channel.hasPrefix("ch")
    }
}
