//
//  HLSMultivariantRepair.swift
//  PlaybackKit
//
//  Repairs HLS multivariant ("master") playlists that AVPlayer rejects. A real-world HDR10 playlist lacks VIDEO-RANGE
//  and FRAME-RATE and uses a bare CODECS="hvc1", and AVPlayer fails it with -12927 (-1002 once only FRAME-RATE is
//  missing) although its media playlists play. The repair probes the first variant's init segment (and first segment
//  for the frame rate), fills in the missing attributes, makes every URI absolute, and the engine serves the result
//  through PlaylistResourceLoader. Media playlists stay on the origin.
//

import Foundation

/// What probing a variant found.
public nonisolated struct HLSRepairProbe: Equatable, Sendable {
    public var video: MediaTrackInfo?
    public var audio: MediaTrackInfo?

    public init(video: MediaTrackInfo?, audio: MediaTrackInfo?) {
        self.video = video
        self.audio = audio
    }
}

public nonisolated enum HLSMultivariantRepair {
    static let playlistLimit = 2 << 20

    /// True for the AVPlayer errors a repaired playlist can fix: -12927, -12646 or -1002 anywhere in the chain.
    public static func isRepairTrigger(_ error: any Error) -> Bool {
        PlaybackErrorMapping.isMultivariantRejection(error)
    }

    /// True when any variant lacks VIDEO-RANGE or FRAME-RATE (video variants), or a complete CODECS.
    public static func needsRepair(_ playlist: HLSMultivariantPlaylist) -> Bool {
        playlist.variants.contains { variantNeedsRepair($0.attributes) }
    }

    public static func variantNeedsRepair(_ attributes: HLSAttributeList) -> Bool {
        let codecs = codecList(attributes)
        if codecs.isEmpty || codecs.contains(where: { !HLSCodecs.isComplete($0) }) { return true }
        guard isVideoVariant(attributes) else { return false }
        return !attributes.contains("VIDEO-RANGE") || !attributes.contains("FRAME-RATE")
    }

    /// Fetches the playlist at `url` and returns a repaired copy, or nil when it should be played as it is: it is
    /// a media playlist, it needs no repair (unless `force`), or probing found nothing to repair it with.
    @concurrent
    public static func prepare(url: URL, fetcher: any MediaResourceFetching,
                               force: Bool) async throws -> HLSPresentation? {
        guard let playlist = try await fetchMultivariant(url: url, fetcher: fetcher) else { return nil }
        return await prepare(playlist, url: url, fetcher: fetcher, force: force)
    }

    /// Fetches the playlist at `url`; nil when it is a media playlist or not a playlist at all.
    @concurrent
    public static func fetchMultivariant(url: URL,
                                         fetcher: any MediaResourceFetching) async throws -> HLSMultivariantPlaylist? {
        let data = try await fetcher.fetch(url, range: nil, maxBytes: playlistLimit)
        guard let text = String(bytes: data, encoding: .utf8), let playlist = HLSMultivariantPlaylist(text: text),
              playlist.isMultivariant else { return nil }
        return playlist
    }

    /// The repaired copy of `playlist`, fetched from `url`, or nil when it needs no repair (unless `force`) or
    /// probing found nothing to repair it with.
    @concurrent
    public static func prepare(_ playlist: HLSMultivariantPlaylist, url: URL, fetcher: any MediaResourceFetching,
                               force: Bool) async -> HLSPresentation? {
        guard playlist.isMultivariant, force || needsRepair(playlist),
              let variant = probedVariant(in: playlist),
              let variantURL = URL(string: variant.uri, relativeTo: url)?.absoluteURL else { return nil }
        let tracks = await MediaProbe.mediaPlaylistTracks(url: variantURL, fetcher: fetcher,
                                                          measureFrameRate: !variant.attributes.contains("FRAME-RATE"))
        var probe = HLSRepairProbe(video: tracks.first { $0.kind == .video }, audio: tracks.first { $0.kind == .audio })
        if probe.audio == nil, needsAudioProbe(variant.attributes), let group = variant.attributes["AUDIO"],
           let uri = playlist.defaultAudioRendition(group: group)?["URI"],
           let renditionURL = URL(string: uri, relativeTo: url)?.absoluteURL {
            let audioTracks = await MediaProbe.mediaPlaylistTracks(url: renditionURL, fetcher: fetcher,
                                                                   measureFrameRate: false)
            probe.audio = audioTracks.first { $0.kind == .audio }
        }
        guard probe.video != nil || probe.audio != nil else { return nil }
        return HLSPresentation(multivariantPlaylist: rewrite(playlist, baseURL: url, probe: probe), mediaPlaylists: [:],
                               streamInfo: streamInfo(playlist: playlist, variant: variant, probe: probe))
    }

    /// The repaired playlist text: every URI absolute against `baseURL`, and missing VIDEO-RANGE, FRAME-RATE and
    /// incomplete CODECS filled from `probe`. Complete CODECS entries and every other line are kept as written.
    public static func rewrite(_ playlist: HLSMultivariantPlaylist, baseURL: URL, probe: HLSRepairProbe) -> String {
        var lines = playlist.lines
        let probedLine = probedVariant(in: playlist)?.tagLine
        for index in lines.indices where !lines[index].isEmpty {
            let line = lines[index]
            guard line.hasPrefix("#") else {
                lines[index] = absolute(line, baseURL: baseURL)
                continue
            }
            guard line.hasPrefix("#EXT-X-"), let colon = line.firstIndex(of: ":") else { continue }
            let tag = line[..<colon]
            var attributes = HLSAttributeList(parsing: line[line.index(after: colon)...])
            var changed = absolutizeURIs(&attributes, baseURL: baseURL)
            if tag == "#EXT-X-STREAM-INF" {
                changed = repair(&attributes, probe: probe, isProbed: index == probedLine) || changed
            }
            if changed {
                lines[index] = "\(tag):\(attributes.text)"
            }
        }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Helpers

    static func codecList(_ attributes: HLSAttributeList) -> [String] {
        (attributes["CODECS"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func isVideoVariant(_ attributes: HLSAttributeList) -> Bool {
        attributes.contains("RESOLUTION") || codecList(attributes).contains(where: HLSCodecs.isVideo)
    }

    /// The variant to probe: the first that may carry video, else the first.
    static func probedVariant(in playlist: HLSMultivariantPlaylist) -> HLSMultivariantPlaylist.Variant? {
        playlist.variants.first { isVideoVariant($0.attributes) || codecList($0.attributes).isEmpty }
            ?? playlist.variants.first
    }

    private static func needsAudioProbe(_ attributes: HLSAttributeList) -> Bool {
        let codecs = codecList(attributes)
        return codecs.isEmpty || codecs.contains { !HLSCodecs.isVideo($0) && !HLSCodecs.isComplete($0) }
    }

    /// Fills the variant's missing attributes. Video codec strings are only taken over by the probed variant
    /// (other variants may use another profile or level; AVPlayer tolerates their bare codecs). Range and frame
    /// rate are applied to every video variant that lacks them.
    private static func repair(_ attributes: inout HLSAttributeList, probe: HLSRepairProbe, isProbed: Bool) -> Bool {
        guard variantNeedsRepair(attributes) else { return false }
        var codecs = codecList(attributes)
        let isVideo = isVideoVariant(attributes) || (codecs.isEmpty && probe.video != nil)
        if codecs.isEmpty {
            codecs = isProbed ? [probe.video?.codecs, probe.audio?.codecs].compactMap { $0 } : []
        } else {
            codecs = codecs.map { codec in
                let replacement = HLSCodecs.isVideo(codec) ? (isProbed ? probe.video : nil) : probe.audio
                guard !HLSCodecs.isComplete(codec), let replacement, HLSCodecs.isComplete(replacement.codecs),
                      HLSCodecs.family(of: replacement.codecs) == HLSCodecs.family(of: codec) else { return codec }
                return replacement.codecs
            }
        }
        if !codecs.isEmpty {
            attributes.set("CODECS", rawValue: HLSPlaylistWriter.quoted(codecs.joined(separator: ",")))
        }
        if isVideo {
            if !attributes.contains("VIDEO-RANGE"), let range = probe.video?.videoRange {
                attributes.set("VIDEO-RANGE", rawValue: range.rawValue)
            }
            if !attributes.contains("FRAME-RATE") {
                let rate = probe.video?.frameRate ?? DASHToHLSTranslator.fallbackFrameRate
                attributes.set("FRAME-RATE", rawValue: HLSPlaylistWriter.decimal(rate, places: 3))
            }
        }
        return true
    }

    /// Makes `URI` and `*-URI` attribute values absolute. Returns true when anything changed.
    private static func absolutizeURIs(_ attributes: inout HLSAttributeList, baseURL: URL) -> Bool {
        var changed = false
        for attribute in attributes.attributes where attribute.name == "URI" || attribute.name.hasSuffix("-URI") {
            guard let value = attributes[attribute.name] else { continue }
            let resolved = absolute(value, baseURL: baseURL)
            if resolved != value {
                attributes.set(attribute.name, rawValue: HLSPlaylistWriter.quoted(resolved))
                changed = true
            }
        }
        return changed
    }

    private static func absolute(_ uri: String, baseURL: URL) -> String {
        URL(string: uri, relativeTo: baseURL)?.absoluteString ?? uri
    }

    private static func streamInfo(playlist: HLSMultivariantPlaylist, variant: HLSMultivariantPlaylist.Variant,
                                   probe: HLSRepairProbe) -> PlaybackStreamInfo {
        var info = PlaybackStreamInfo(isLive: false)
        if let video = probe.video {
            info.videoCodec = HLSCodecs.displayName(of: video.codecs)
            info.width = video.width
            info.height = video.height
            info.frameRate = video.frameRate
        }
        let rendition = variant.attributes["AUDIO"].flatMap { playlist.defaultAudioRendition(group: $0) }
        let audioCodec = probe.audio?.codecs ?? codecList(variant.attributes).first { !HLSCodecs.isVideo($0) }
        info.audioCodec = audioCodec.map(HLSCodecs.displayName)
        info.audioChannels = probe.audio?.audioChannels
            ?? rendition?["CHANNELS"].flatMap { Int($0.prefix { $0.isNumber }) }
        info.audioLanguage = rendition?["LANGUAGE"]
        return info
    }
}
