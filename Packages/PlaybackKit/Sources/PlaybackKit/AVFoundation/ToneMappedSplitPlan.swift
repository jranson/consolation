//
//  ToneMappedSplitPlan.swift
//  PlaybackKit
//
//  When the display can't show HDR (`AVPlayer.eligibleForHDRPlayback` is false, as on an SDR monitor or an Apple TV in
//  SDR mode), AVPlayer drops every PQ and HLG variant of a multivariant playlist and refuses one with nothing left
//  (AVFoundation -11868 / CoreMedia -17223), yet it tone-maps an HDR media playlist played on its own. For an HDR-only
//  presentation the engine then plays the video variant's media playlist on its main player and the audio rendition's
//  on a second, video-less player kept in sync (`SplitAudioFollower`). This file holds the pure decisions: whether to
//  split, and which media playlists to play.
//

import AVFoundation
import Foundation

/// Whether the display can show HDR, as the engine should assume it.
public nonisolated enum HDRDisplayEligibility: Equatable, Sendable {
    /// `AVPlayer.eligibleForHDRPlayback`, read when a stream loads.
    case system
    case eligible
    case ineligible
}

/// The media playlists to play when an HDR-only presentation is played without its multivariant playlist.
public nonisolated struct ToneMappedSplitPlan: Equatable, Sendable {
    public nonisolated struct AudioRendition: Equatable, Sendable {
        public var name: String?
        public var language: String?
        public var url: URL
        public var isDefault: Bool
    }

    /// The chosen video variant's media playlist.
    public var videoURL: URL
    public var videoRange: HLSVideoRange
    /// The variant's BANDWIDTH, for the log line.
    public var bandwidth: Int
    /// The audio renditions of the variant's AUDIO group that have their own media playlist.
    public var renditions: [AudioRendition]
    /// Index into `renditions` of the one to play; nil when the variant has no separate audio.
    public var selectedAudio: Int?

    public var selectedAudioURL: URL? {
        selectedAudio.map { renditions[$0].url }
    }

    /// The plan for `playlist`, whose URIs resolve against `baseURL`; nil without a video variant. The video
    /// variant is the highest-bandwidth one whose codecs `canDecode` accepts (the highest overall when none is),
    /// and the audio rendition is its group's DEFAULT=YES one, else its first.
    public init?(playlist: HLSMultivariantPlaylist, baseURL: URL,
                 canDecode: (String) -> Bool = ToneMappedSplitPlan.deviceCanDecode) {
        let videos = playlist.variants.filter { HLSMultivariantRepair.isVideoVariant($0.attributes) }
        let decodable = videos.filter { variant in
            let codecs = HLSMultivariantRepair.codecList(variant.attributes)
            return codecs.isEmpty || canDecode(codecs.joined(separator: ","))
        }
        let candidates = decodable.isEmpty ? videos : decodable
        guard let variant = candidates.max(by: { Self.bandwidth($0) < Self.bandwidth($1) }),
              let videoURL = URL(string: variant.uri, relativeTo: baseURL)?.absoluteURL else { return nil }
        self.videoURL = videoURL
        self.videoRange = Self.range(of: variant) ?? .sdr
        self.bandwidth = Self.bandwidth(variant)
        let group = variant.attributes["AUDIO"]
        let entries = playlist.renditions.filter { $0["TYPE"] == "AUDIO" && group != nil && $0["GROUP-ID"] == group }
        renditions = entries.compactMap { entry in
            guard let uri = entry["URI"], let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL else {
                return nil
            }
            return AudioRendition(name: entry["NAME"], language: entry["LANGUAGE"], url: url,
                                  isDefault: entry["DEFAULT"] == "YES")
        }
        selectedAudio = renditions.isEmpty ? nil : (renditions.firstIndex(where: \.isDefault) ?? 0)
    }

    /// True when the playlist has video variants and every one declares VIDEO-RANGE=PQ or HLG.
    public static func isHDROnly(_ playlist: HLSMultivariantPlaylist) -> Bool {
        let videos = playlist.variants.filter { HLSMultivariantRepair.isVideoVariant($0.attributes) }
        return !videos.isEmpty && videos.allSatisfy { range(of: $0).map { $0 != .sdr } ?? false }
    }

    /// Split only when the display can't show HDR and nothing but HDR is on offer; otherwise the multivariant
    /// playlist plays as usual, with adaptive bit rate.
    public static func shouldSplit(_ playlist: HLSMultivariantPlaylist, hdrEligible: Bool) -> Bool {
        !hdrEligible && isHDROnly(playlist)
    }

    /// Whether this device decodes `codecs` (an HLS CODECS value) in an MP4 container.
    public static func deviceCanDecode(_ codecs: String) -> Bool {
        AVURLAsset.isPlayableExtendedMIMEType("video/mp4; codecs=\"\(codecs)\"")
    }

    static func range(of variant: HLSMultivariantPlaylist.Variant) -> HLSVideoRange? {
        variant.attributes["VIDEO-RANGE"].flatMap(HLSVideoRange.init(rawValue:))
    }

    static func bandwidth(_ variant: HLSMultivariantPlaylist.Variant) -> Int {
        variant.attributes["BANDWIDTH"].flatMap { Int($0) } ?? 0
    }
}
