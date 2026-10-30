//
//  DASHToHLSTranslator.swift
//  PlaybackKit
//
//  Translates a static DASH MPD into an HLS multivariant playlist plus one VOD media playlist per selected
//  Representation, with absolute init and segment URLs. AVPlayer needs VIDEO-RANGE, FRAME-RATE and complete CODECS,
//  which MPDs often lack, so codecs, range and frame rate come from the init segments when the caller has probed them
//  (see `DASHPresentationLoader`).
//

import Foundation

/// The Representations a translation uses.
public nonisolated struct DASHSelection: Equatable, Sendable {
    public var period: DASHPeriod
    /// Seconds; bounds `@r="-1"` timelines and `@duration` templates.
    public var periodDuration: Double?
    /// Video Representations that become `EXT-X-STREAM-INF` variants, in playlist order.
    public var videos: [DASHRepresentation]
    /// Audio renditions, one per audio AdaptationSet.
    public var audios: [DASHAudioChoice]

    /// Everything whose init segment is worth probing: every video, and audio whose codecs or channels are unknown.
    public var representationsToProbe: [DASHRepresentation] {
        let audio = audios.map(\.representation).filter { rep in
            rep.audioChannels == nil || !(rep.codecs.map(HLSCodecs.isComplete) ?? false)
        }
        return videos + audio
    }
}

public nonisolated struct DASHAudioChoice: Equatable, Sendable {
    public var language: String?
    public var isMain: Bool
    public var representation: DASHRepresentation
}

public nonisolated struct DASHToHLSTranslator: Sendable {
    public nonisolated enum VariantPolicy: Equatable, Sendable {
        /// The highest-bandwidth video Representation of each video AdaptationSet.
        case bestPerAdaptationSet
        /// Every video Representation, so AVPlayer can switch bitrates.
        case allRepresentations
    }

    /// Written as FRAME-RATE when neither the MPD nor the init segment says; AVPlayer rejects some variants
    /// without one (-1002), and the value only informs variant selection.
    public static let fallbackFrameRate = 30.0
    static let audioGroupID = "audio"

    public let manifest: DASHManifest
    public let policy: VariantPolicy

    public init(manifest: DASHManifest, policy: VariantPolicy = .bestPerAdaptationSet) {
        self.manifest = manifest
        self.policy = policy
    }

    /// Picks the Period and Representations to translate. Only the first Period is used (multi-period is deferred).
    public func selection() throws(DASHManifestError) -> DASHSelection {
        guard manifest.presentationType == .staticPresentation else { throw .unsupported("dynamic MPD") }
        guard let period = manifest.periods.first else { throw .noPeriods }
        var unsupported: String?
        func usable(_ reps: [DASHRepresentation]) -> [DASHRepresentation] {
            unsupported = unsupported ?? reps.lazy.compactMap(\.unsupportedAddressing).first
            return reps.filter { $0.unsupportedAddressing == nil && $0.segmentTemplate?.media != nil }
        }
        var videos: [DASHRepresentation] = []
        var audios: [DASHAudioChoice] = []
        for set in period.adaptationSets {
            switch set.contentType {
            case .video:
                let candidates = usable(set.representations)
                if policy == .allRepresentations {
                    videos += candidates
                } else if let best = candidates.max(by: { $0.bandwidth < $1.bandwidth }) {
                    videos.append(best)
                }
            case .audio:
                if let best = usable(set.representations).max(by: { $0.bandwidth < $1.bandwidth }) {
                    audios.append(DASHAudioChoice(language: set.language, isMain: set.isMain, representation: best))
                }
            case .text, .other:
                continue
            }
        }
        guard !videos.isEmpty || !audios.isEmpty else {
            if let unsupported { throw .unsupported(unsupported) }
            throw .noPlayableRepresentations
        }
        return DASHSelection(period: period, periodDuration: manifest.duration(of: period), videos: videos,
                             audios: audios)
    }

    /// Translates with a fresh selection.
    public func translate(probes: [String: MediaTrackInfo] = [:]) throws(DASHManifestError) -> HLSPresentation {
        try translate(selection: selection(), probes: probes)
    }

    /// Builds the playlists. `probes` holds init-segment facts by Representation ID.
    public func translate(selection: DASHSelection,
                          probes: [String: MediaTrackInfo]) throws(DASHManifestError) -> HLSPresentation {
        var media: [String: String] = [:]
        var renditions: [HLSAudioRenditionEntry] = []
        var audioCodecs: [String] = []
        let defaultAudio = selection.audios.firstIndex(where: \.isMain) ?? 0
        var usedNames: Set<String> = []
        for (index, choice) in selection.audios.enumerated() {
            let rep = choice.representation
            let uri = "audio-\(index).m3u8"
            media[uri] = try mediaPlaylist(rep, selection: selection)
            for codec in Self.codecs(declared: rep.codecs, probe: probes[rep.id]) where !audioCodecs.contains(codec) {
                audioCodecs.append(codec)
            }
            let name = Self.uniqueName(choice.language ?? "Audio \(index + 1)", used: &usedNames)
            renditions.append(HLSAudioRenditionEntry(groupID: Self.audioGroupID, name: name, language: choice.language,
                                                     isDefault: index == defaultAudio,
                                                     channels: rep.audioChannels ?? probes[rep.id]?.audioChannels,
                                                     uri: uri))
        }
        var variants: [HLSVariantEntry] = []
        let audioBandwidth = selection.audios.map(\.representation.bandwidth).max() ?? 0
        for (index, rep) in selection.videos.enumerated() {
            let uri = "video-\(index).m3u8"
            media[uri] = try mediaPlaylist(rep, selection: selection)
            let probe = probes[rep.id]
            let range = rep.transferCharacteristics.map(HLSVideoRange.init) ?? probe?.videoRange ?? .sdr
            let codecs = Self.codecs(declared: rep.codecs, probe: probe) + audioCodecs
            let (bandwidth, overflow) = rep.bandwidth.addingReportingOverflow(audioBandwidth)
            variants.append(HLSVariantEntry(
                bandwidth: overflow ? Int.max : bandwidth, width: rep.width ?? probe?.width,
                height: rep.height ?? probe?.height, codecs: codecs,
                videoRange: range, frameRate: rep.frameRate ?? probe?.frameRate ?? Self.fallbackFrameRate,
                audioGroup: renditions.isEmpty ? nil : Self.audioGroupID, uri: uri))
        }
        if variants.isEmpty {
            variants = selection.audios.enumerated().map { index, choice in
                let rep = choice.representation
                return HLSVariantEntry(bandwidth: rep.bandwidth, codecs: Self.codecs(declared: rep.codecs,
                                                                                    probe: probes[rep.id]),
                                       uri: "audio-\(index).m3u8")
            }
            renditions = []
        }
        let playlist = HLSPlaylistWriter.multivariantPlaylist(variants: variants, renditions: renditions)
        return HLSPresentation(multivariantPlaylist: playlist, mediaPlaylists: media,
                               streamInfo: streamInfo(selection: selection, variants: variants, probes: probes))
    }

    private func mediaPlaylist(_ rep: DASHRepresentation,
                               selection: DASHSelection) throws(DASHManifestError) -> String {
        let segments = try rep.segments(periodDuration: selection.periodDuration)
        guard let first = segments.first else { throw .missingSegmentInformation(representationID: rep.id) }
        return HLSPlaylistWriter.mediaPlaylist(initURL: try rep.initializationURL(), segments: segments,
                                               firstSequence: first.number)
    }

    /// The declared codecs, with incomplete entries replaced by the init segment's string of the same family.
    static func codecs(declared: String?, probe: MediaTrackInfo?) -> [String] {
        let entries = (declared ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !entries.isEmpty else { return probe.map { [$0.codecs] } ?? [] }
        return entries.map { codec in
            guard !HLSCodecs.isComplete(codec), let probe, HLSCodecs.isComplete(probe.codecs),
                  HLSCodecs.family(of: probe.codecs) == HLSCodecs.family(of: codec) else { return codec }
            return probe.codecs
        }
    }

    private static func uniqueName(_ base: String, used: inout Set<String>) -> String {
        var name = base
        var suffix = 2
        while used.contains(name) {
            name = "\(base) \(suffix)"
            suffix += 1
        }
        used.insert(name)
        return name
    }

    private func streamInfo(selection: DASHSelection, variants: [HLSVariantEntry],
                            probes: [String: MediaTrackInfo]) -> PlaybackStreamInfo {
        var info = PlaybackStreamInfo(isLive: false)
        if let video = selection.videos.first, let variant = variants.first {
            info.videoCodec = variant.codecs.first.map(HLSCodecs.displayName)
            info.width = variant.width
            info.height = variant.height
            info.frameRate = video.frameRate ?? probes[video.id]?.frameRate
        }
        let defaultIndex = selection.audios.firstIndex(where: \.isMain) ?? 0
        if selection.audios.indices.contains(defaultIndex) {
            let audio = selection.audios[defaultIndex]
            let rep = audio.representation
            info.audioCodec = Self.codecs(declared: rep.codecs, probe: probes[rep.id]).first.map(HLSCodecs.displayName)
            info.audioChannels = rep.audioChannels ?? probes[rep.id]?.audioChannels
            info.audioLanguage = audio.language
        }
        return info
    }
}
