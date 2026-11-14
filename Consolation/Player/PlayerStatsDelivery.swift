//
//  PlayerStatsDelivery.swift
//  Consolation
//
//  How the playing stream reaches the player (HLS, MPEG-DASH, a continuous HTTP stream, a local file), for the
//  Video Stats overlay's Protocol line. Only the scheme of a URL is ever shown, never the URL.
//

import Foundation
import MediaSourceKit
import PlaybackKit

extension PlayerStats {
    nonisolated struct Delivery: Equatable {
        let text: String
        var isHLS = false
    }

    /// The protocol line for `engine` playing `item`.
    static func delivery(of engine: any PlaybackEngine, item: PlayingItem?) -> Delivery? {
        if let player = engine as? AVPlayerEngine {
            return delivery(kind: player.inputKind, url: player.url, route: player.route)
        }
        guard engine is TransportStreamEngine || engine is MatroskaEngine else { return nil }
        let isSeekable = engine is MatroskaEngine
        switch item {
        case .channel:
            return Delivery(text: "HTTP stream (tuner)")
        case .url(let url):
            return byteStream(url: url, isSeekable: isSeekable)
        case .media(let media):
            return byteStream(input: media.input, isLive: media.isLive)
        case nil:
            return nil
        }
    }

    /// AVPlayer's inputs: adaptive streaming or a progressive file.
    nonisolated static func delivery(kind: AVPlayerEngine.InputKind, url: URL,
                                     route: AVPlayerEngine.Route?) -> Delivery {
        let scheme = transport(of: url)
        switch kind {
        case .hls:
            let note = switch route {
            case .repairedMultivariant: " (repaired)"
            case .toneMappedSplit: " (tone-mapped split)"
            default: ""
            }
            return Delivery(text: "HLS/\(scheme)\(note)", isHLS: true)
        case .dash:
            return Delivery(text: "DASH/\(scheme) (as HLS)")
        case .file:
            return Delivery(text: url.isFileURL ? "Local file" : "\(scheme) progressive")
        }
    }

    /// A URL our own demuxers read: one long response, or range requests where the engine seeks.
    nonisolated static func byteStream(url: URL, isSeekable: Bool) -> Delivery {
        if url.isFileURL { return Delivery(text: "Local file") }
        let scheme = transport(of: url)
        return Delivery(text: isSeekable ? "\(scheme) ranges" : "\(scheme) stream")
    }

    /// A library source's item: its source made the byte source, so only its shape is known here.
    nonisolated private static func byteStream(input: EngineInput, isLive: Bool) -> Delivery? {
        switch input {
        case .avPlayer(let player):
            delivery(kind: player.kind, url: player.url, route: nil)
        case .transportStream(let feed):
            switch feed.growth {
            case .live: Delivery(text: feed.channel == nil ? "Stream" : "HTTP stream (tuner)")
            case .growingFile: Delivery(text: "Growing file")
            case .complete: Delivery(text: "Byte stream")
            }
        case .matroska:
            Delivery(text: isLive ? "Stream" : "Byte ranges")
        }
    }

    nonisolated private static func transport(of url: URL) -> String {
        switch url.scheme?.lowercased() {
        case "https": "HTTPS"
        case "http": "HTTP"
        case "file": "file"
        case let scheme?: scheme.uppercased()
        case nil: "HTTP"
        }
    }
}
