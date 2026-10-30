//
//  HLSPlaylistWriter.swift
//  PlaybackKit
//
//  Text generation for HLS multivariant and media playlists (RFC 8216), and codec-string helpers shared by the
//  DASH translator and the multivariant playlist repair.
//

import Foundation

/// A generated HLS presentation: one multivariant playlist plus media playlists served next to it.
public nonisolated struct HLSPresentation: Equatable, Sendable {
    /// The file name the multivariant playlist is served under.
    public static let multivariantName = "multivariant.m3u8"

    public var multivariantPlaylist: String
    /// Media playlists by file name, relative to the multivariant playlist. Empty when they stay on the origin.
    public var mediaPlaylists: [String: String]
    /// What is known about the stream before AVPlayer opens it, used to seed `PlaybackEngine.streamInfo`.
    public var streamInfo: PlaybackStreamInfo

    public init(multivariantPlaylist: String, mediaPlaylists: [String: String], streamInfo: PlaybackStreamInfo) {
        self.multivariantPlaylist = multivariantPlaylist
        self.mediaPlaylists = mediaPlaylists
        self.streamInfo = streamInfo
    }
}

/// One `EXT-X-STREAM-INF` and its URI.
nonisolated struct HLSVariantEntry: Equatable, Sendable {
    var bandwidth: Int
    var width: Int?
    var height: Int?
    var codecs: [String]
    var videoRange: HLSVideoRange?
    var frameRate: Double?
    var audioGroup: String?
    var uri: String
}

/// One `EXT-X-MEDIA:TYPE=AUDIO`.
nonisolated struct HLSAudioRenditionEntry: Equatable, Sendable {
    var groupID: String
    var name: String
    var language: String?
    var isDefault: Bool
    var channels: Int?
    var uri: String
}

nonisolated enum HLSPlaylistWriter {
    static func multivariantPlaylist(variants: [HLSVariantEntry], renditions: [HLSAudioRenditionEntry]) -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
        for rendition in renditions {
            var attributes = ["TYPE=AUDIO", "GROUP-ID=\(quoted(rendition.groupID))", "NAME=\(quoted(rendition.name))"]
            if let language = rendition.language {
                attributes.append("LANGUAGE=\(quoted(language))")
            }
            attributes.append("DEFAULT=\(rendition.isDefault ? "YES" : "NO")")
            attributes.append("AUTOSELECT=YES")
            if let channels = rendition.channels {
                attributes.append("CHANNELS=\(quoted(String(channels)))")
            }
            attributes.append("URI=\(quoted(rendition.uri))")
            lines.append("#EXT-X-MEDIA:" + attributes.joined(separator: ","))
        }
        for variant in variants {
            var attributes = ["BANDWIDTH=\(max(variant.bandwidth, 1))"]
            if let width = variant.width, let height = variant.height {
                attributes.append("RESOLUTION=\(width)x\(height)")
            }
            if !variant.codecs.isEmpty {
                attributes.append("CODECS=\(quoted(variant.codecs.joined(separator: ",")))")
            }
            if let range = variant.videoRange {
                attributes.append("VIDEO-RANGE=\(range.rawValue)")
            }
            if let frameRate = variant.frameRate {
                attributes.append("FRAME-RATE=\(decimal(frameRate, places: 3))")
            }
            if let group = variant.audioGroup {
                attributes.append("AUDIO=\(quoted(group))")
            }
            lines.append("#EXT-X-STREAM-INF:" + attributes.joined(separator: ","))
            lines.append(variant.uri)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A VOD media playlist with absolute init and segment URLs.
    static func mediaPlaylist(initURL: URL?, segments: [DASHSegment], firstSequence: Int) -> String {
        let longest = segments.map { min($0.duration, 86_400).rounded() }.max() ?? 1
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(max(1, Int(longest)))",
                     "#EXT-X-MEDIA-SEQUENCE:\(max(0, firstSequence))", "#EXT-X-PLAYLIST-TYPE:VOD"]
        lines.reserveCapacity(lines.count + segments.count * 2 + 2)
        if let initURL {
            lines.append("#EXT-X-MAP:URI=\(quoted(initURL.absoluteString))")
        }
        for segment in segments {
            lines.append("#EXTINF:\(decimal(segment.duration, places: 5)),")
            lines.append(segment.url.absoluteString)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    /// A quoted-string attribute value. Characters that a quoted-string can't hold are dropped.
    static func quoted(_ value: String) -> String {
        "\"" + value.filter { $0 != "\"" && $0 != "\n" && $0 != "\r" } + "\""
    }

    /// Fixed-point decimal, independent of the user's locale.
    static func decimal(_ value: Double, places: Int) -> String {
        String(format: "%.\(places)f", value)
    }
}

/// RFC 6381 codec-string helpers.
public nonisolated enum HLSCodecs {
    /// True when `codec` carries enough detail for AVFoundation's variant selection (`hvc1.2.4.L150.90`, not
    /// `hvc1`). Unknown codecs count as complete.
    public static func isComplete(_ codec: String) -> Bool {
        let parts = codec.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        switch family(of: codec) {
        case "hevc", "av1", "vp9":
            return parts.count >= 4
        case "dolbyVision":
            return parts.count >= 3
        case "avc":
            return parts.count >= 2 && parts[1].count == 6
        case "aac":
            return parts.count >= 2 && (parts[1] != "40" || parts.count >= 3)
        default:
            return true
        }
    }

    /// A coarse codec family, so that `hev1` from an MPD and `hvc1` from an init segment are recognised as one.
    public static func family(of codec: String) -> String? {
        let fourCC = codec.trimmingCharacters(in: .whitespaces).split(separator: ".").first.map(String.init) ?? ""
        switch fourCC.lowercased() {
        case "hvc1", "hev1": return "hevc"
        case "dvh1", "dvhe": return "dolbyVision"
        case "avc1", "avc3": return "avc"
        case "av01": return "av1"
        case "vp09": return "vp9"
        case "mp4a", "aac": return "aac"
        case ".mp3", "mp3": return "mp3"
        case "ac-3": return "ac3"
        case "ec-3": return "eac3"
        case "ac-4": return "ac4"
        case "opus": return "opus"
        case "flac": return "flac"
        default: return nil
        }
    }

    /// True for video codec families.
    public static func isVideo(_ codec: String) -> Bool {
        ["hevc", "dolbyVision", "avc", "av1", "vp9"].contains(family(of: codec) ?? "")
    }

    /// A short name for the stats overlay: `HEVC`, `H.264`, `AAC`, `E-AC-3`…
    public static func displayName(of codec: String) -> String {
        let names = ["hevc": "HEVC", "dolbyVision": "Dolby Vision", "avc": "H.264", "av1": "AV1", "vp9": "VP9",
                     "aac": "AAC", "mp3": "MP3", "ac3": "AC-3", "eac3": "E-AC-3", "ac4": "AC-4", "opus": "Opus",
                     "flac": "FLAC"]
        return family(of: codec).flatMap { names[$0] } ?? codec
    }
}
