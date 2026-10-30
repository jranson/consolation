//
//  ISOInitSegment.swift
//  PlaybackKit
//
//  Reads the tracks of an fMP4 init segment (moov/trak/mdia/minf/stbl/stsd) far enough to write HLS CODECS,
//  VIDEO-RANGE, RESOLUTION and CHANNELS attributes.
//

import Foundation

/// What an init segment says about one track.
public nonisolated struct MediaTrackInfo: Equatable, Sendable {
    public nonisolated enum Kind: String, Equatable, Sendable {
        case video
        case audio
        case other
    }

    public var kind: Kind
    public var trackID: UInt32?
    public var timescale: UInt32?
    /// The sample entry type, such as `hvc1`, `avc1`, `mp4a`, `ec-3`.
    public var sampleEntry: String
    /// The RFC 6381 codec string, or the sample entry type when no configuration box allows more.
    public var codecs: String
    public var width: Int?
    public var height: Int?
    public var transferCharacteristics: Int?
    public var audioChannels: Int?
    public var sampleRate: Int?
    /// `trex` default sample duration, used when a fragment's `trun` and `tfhd` carry none.
    public var defaultSampleDuration: UInt32?
    /// Frames per second, when a media fragment was probed.
    public var frameRate: Double?

    public init(kind: Kind, sampleEntry: String, codecs: String) {
        self.kind = kind
        self.sampleEntry = sampleEntry
        self.codecs = codecs
    }

    /// `VIDEO-RANGE` for this track; SDR when the init segment has no `colr` box.
    public var videoRange: HLSVideoRange? {
        guard kind == .video else { return nil }
        return transferCharacteristics.map { HLSVideoRange(transferCharacteristics: $0) } ?? .sdr
    }
}

nonisolated enum ISOInitSegment {
    static let videoEntries: Set<String> = ["hvc1", "hev1", "avc1", "avc3", "dvh1", "dvhe", "av01", "vp09"]
    static let audioEntries: Set<String> = ["mp4a", "ac-3", "ec-3", "ac-4", "Opus", "fLaC", "alac", ".mp3"]

    /// Every track in the init segment, in file order. Returns an empty array for anything that isn't one.
    static func tracks(in data: Data) -> [MediaTrackInfo] {
        let reader = ISOBMFFReader(data)
        guard let moov = reader.firstBox("moov", in: reader.fullRange) else { return [] }
        let defaults = trackDefaults(reader: reader, moov: moov)
        return reader.boxes(in: moov.payload).filter { $0.type == "trak" }.prefix(16).compactMap { trak in
            var track = parseTrack(reader: reader, trak: trak)
            if let id = track?.trackID {
                track?.defaultSampleDuration = defaults[id]
            }
            return track
        }
    }

    /// `trex` default sample durations by track ID.
    private static func trackDefaults(reader: ISOBMFFReader, moov: ISOBox) -> [UInt32: UInt32] {
        guard let mvex = reader.firstBox("mvex", in: moov.payload) else { return [:] }
        var result: [UInt32: UInt32] = [:]
        for trex in reader.boxes(in: mvex.payload) where trex.type == "trex" {
            let base = trex.payload.lowerBound
            if let id = reader.uint32(at: base + 4), let duration = reader.uint32(at: base + 12) {
                result[id] = duration
            }
        }
        return result
    }

    private static func parseTrack(reader: ISOBMFFReader, trak: ISOBox) -> MediaTrackInfo? {
        guard let mdia = reader.firstBox("mdia", in: trak.payload),
              let stsd = reader.box(path: ["minf", "stbl", "stsd"], in: mdia.payload),
              let entriesRange = reader.subrange(of: stsd.payload, from: 8),
              let entry = reader.boxes(in: entriesRange).first else { return nil }
        let handler = reader.firstBox("hdlr", in: mdia.payload).flatMap { reader.fourCC(at: $0.payload.lowerBound + 8) }
        var track: MediaTrackInfo
        if handler == "vide" || (handler == nil && videoEntries.contains(entry.type)) {
            track = videoTrack(reader: reader, entry: entry)
        } else if handler == "soun" || (handler == nil && audioEntries.contains(entry.type)) {
            track = audioTrack(reader: reader, entry: entry)
        } else {
            track = MediaTrackInfo(kind: .other, sampleEntry: entry.type, codecs: entry.type)
        }
        if let tkhd = reader.firstBox("tkhd", in: trak.payload),
           let header = reader.fullBoxHeader(at: tkhd.payload.lowerBound) {
            let idOffset = header.version == 1 ? 20 : 12
            track.trackID = reader.uint32(at: tkhd.payload.lowerBound + idOffset)
        }
        if let mdhd = reader.firstBox("mdhd", in: mdia.payload),
           let header = reader.fullBoxHeader(at: mdhd.payload.lowerBound) {
            let scaleOffset = header.version == 1 ? 20 : 12
            track.timescale = reader.uint32(at: mdhd.payload.lowerBound + scaleOffset).flatMap { $0 > 0 ? $0 : nil }
        }
        return track
    }

    /// Visual sample entry: 8 bytes of SampleEntry, 70 bytes of VisualSampleEntry, then child boxes.
    private static func videoTrack(reader: ISOBMFFReader, entry: ISOBox) -> MediaTrackInfo {
        var track = MediaTrackInfo(kind: .video, sampleEntry: entry.type, codecs: entry.type)
        let base = entry.payload.lowerBound
        if entry.payload.count >= 78 {
            track.width = reader.uint16(at: base + 24).map(Int.init)
            track.height = reader.uint16(at: base + 26).map(Int.init)
        }
        guard let children = reader.subrange(of: entry.payload, from: 78) else { return track }
        for child in reader.boxes(in: children) {
            guard let payload = reader.slice(child.payload) else { continue }
            switch child.type {
            case "hvcC":
                track.codecs = ISOCodecStrings.hevc(hvcC: payload, sampleEntry: entry.type) ?? track.codecs
            case "avcC":
                track.codecs = ISOCodecStrings.avc(avcC: payload, sampleEntry: entry.type) ?? track.codecs
            case "colr":
                if let transfer = ISOCodecStrings.transferCharacteristics(colr: payload) {
                    track.transferCharacteristics = transfer
                }
            default:
                break
            }
        }
        return track
    }

    /// Audio sample entry: 8 bytes of SampleEntry, then 20 bytes (QuickTime versions 1 and 2 add 16 or 36 more).
    private static func audioTrack(reader: ISOBMFFReader, entry: ISOBox) -> MediaTrackInfo {
        var track = MediaTrackInfo(kind: .audio, sampleEntry: entry.type, codecs: entry.type)
        let base = entry.payload.lowerBound
        guard entry.payload.count >= 28 else { return track }
        let version = reader.uint16(at: base + 8) ?? 0
        track.audioChannels = reader.uint16(at: base + 16).flatMap { $0 > 0 ? Int($0) : nil }
        track.sampleRate = reader.uint32(at: base + 24).flatMap { $0 >> 16 > 0 ? Int($0 >> 16) : nil }
        let extra = version == 1 ? 16 : (version == 2 ? 36 : 0)
        guard let children = reader.subrange(of: entry.payload, from: 28 + extra) else { return track }
        for child in reader.boxes(in: children) {
            guard let payload = reader.slice(child.payload) else { continue }
            switch child.type {
            case "esds":
                if let config = ISOCodecStrings.mpeg4Audio(esds: payload) {
                    track.codecs = config.codecs
                    track.audioChannels = config.channels ?? track.audioChannels
                    track.sampleRate = config.sampleRate ?? track.sampleRate
                }
            case "dac3":
                track.audioChannels = ISOCodecStrings.ac3Channels(dac3: payload) ?? track.audioChannels
            case "dec3":
                track.audioChannels = ISOCodecStrings.eac3Channels(dec3: payload) ?? track.audioChannels
            default:
                break
            }
        }
        if entry.type == "Opus" || entry.type == "fLaC" {
            track.codecs = entry.type.lowercased()
        }
        return track
    }
}
