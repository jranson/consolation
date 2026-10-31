//
//  MatroskaTrack.swift
//  Matroska
//
//  One TrackEntry of a Segment's Tracks: what the track is, its codec and the facts a player needs to set up a
//  decoder. Defaults follow the specification (enabled, default, English, no compression).
//

import Foundation

nonisolated public struct MatroskaTrack: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case video
        case audio
        case subtitle
        /// Any other TrackType (complex, logo, buttons, control, metadata), with its value.
        case other(UInt64)

        init(_ type: UInt64) {
            switch type {
            case 1: self = .video
            case 2: self = .audio
            case 17: self = .subtitle
            default: self = .other(type)
            }
        }
    }

    /// FlagInterlaced.
    public enum Interlacing: Sendable, Equatable {
        case undetermined
        case interlaced
        case progressive
    }

    public var number: UInt64
    public var kind: Kind
    /// The codec, for example `V_MPEG4/ISO/AVC`, `V_MPEGH/ISO/HEVC`, `A_AAC` or `A_AC3`.
    public var codecID = ""
    /// Codec setup data: `avcC` for H.264, `hvcC` for HEVC, the AudioSpecificConfig for AAC.
    public var codecPrivate = Data()
    /// The ISO 639-2 code from Language ("eng" when absent, as the specification says).
    public var language = "eng"
    /// A BCP 47 tag from LanguageBCP47, which takes precedence over `language` when present.
    public var languageBCP47: String?
    public var name: String?
    public var isEnabled = true
    public var isDefault = true
    public var isForced = false
    /// Nanoseconds per frame, for a track with a constant frame duration.
    public var defaultDuration: UInt64?
    /// Nanoseconds the decoder needs before its output is valid (Opus pre-skip).
    public var codecDelay: UInt64 = 0

    // Video
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var displayWidth: Int?
    public var displayHeight: Int?
    public var interlacing = Interlacing.undetermined

    // Audio
    public var samplingFrequency: Double?
    /// The output rate when it differs from `samplingFrequency` (HE-AAC with SBR).
    public var outputSamplingFrequency: Double?
    public var channels = 1
    public var bitDepth: Int?

    /// Bytes that were stripped from the start of every frame when the file was written (ContentCompAlgo 3, header
    /// stripping), to be put back before a frame is decoded.
    public var strippedHeader: Data?
    /// The frames are compressed (zlib, bzlib, LZO) or encrypted in a way this demuxer doesn't undo.
    public var hasUnsupportedEncoding = false

    public init(number: UInt64, kind: Kind) {
        self.number = number
        self.kind = kind
    }

    /// Bounds on what one Tracks element may describe.
    static let maximumTracks = 128

    /// The track entries of a Tracks payload. Entries without a number or a type are left out.
    static func tracks(in payload: UnsafeBufferPointer<UInt8>) -> [MatroskaTrack] {
        var tracks: [MatroskaTrack] = []
        for child in EBMLChildren(payload) where child.id == MatroskaID.trackEntry {
            if let track = entry(child.payload) { tracks.append(track) }
            if tracks.count >= maximumTracks { break }
        }
        return tracks
    }

    private static func entry(_ payload: UnsafeBufferPointer<UInt8>) -> MatroskaTrack? {
        var number: UInt64?
        var type: UInt64?
        for child in EBMLChildren(payload) {
            if child.id == MatroskaID.trackNumber { number = child.unsigned }
            if child.id == MatroskaID.trackType { type = child.unsigned }
        }
        guard let number, number > 0, let type else { return nil }
        var track = MatroskaTrack(number: number, kind: Kind(type))
        for child in EBMLChildren(payload) {
            track.apply(child)
        }
        return track
    }

    private mutating func apply(_ child: EBMLChildren.Child) {
        switch child.id {
        case MatroskaID.codecID: codecID = child.string
        case MatroskaID.codecPrivate: codecPrivate = child.data
        case MatroskaID.language: language = child.string
        case MatroskaID.languageBCP47: languageBCP47 = child.string
        case MatroskaID.name: name = child.string
        case MatroskaID.flagEnabled: isEnabled = child.flag ?? true
        case MatroskaID.flagDefault: isDefault = child.flag ?? true
        case MatroskaID.flagForced: isForced = child.flag ?? false
        case MatroskaID.defaultDuration: defaultDuration = child.unsigned.flatMap { $0 > 0 ? $0 : nil }
        case MatroskaID.codecDelay: codecDelay = child.unsigned ?? 0
        case MatroskaID.video: applyVideo(child.payload)
        case MatroskaID.audio: applyAudio(child.payload)
        case MatroskaID.contentEncodings: applyEncodings(child.payload)
        default: break
        }
    }

    private mutating func applyVideo(_ payload: UnsafeBufferPointer<UInt8>) {
        for child in EBMLChildren(payload) {
            switch child.id {
            case MatroskaID.pixelWidth: pixelWidth = child.int
            case MatroskaID.pixelHeight: pixelHeight = child.int
            case MatroskaID.displayWidth: displayWidth = child.int
            case MatroskaID.displayHeight: displayHeight = child.int
            case MatroskaID.flagInterlaced:
                switch child.unsigned {
                case 1: interlacing = .interlaced
                case 2: interlacing = .progressive
                default: interlacing = .undetermined
                }
            default: break
            }
        }
    }

    private mutating func applyAudio(_ payload: UnsafeBufferPointer<UInt8>) {
        for child in EBMLChildren(payload) {
            switch child.id {
            case MatroskaID.samplingFrequency: samplingFrequency = child.float
            case MatroskaID.outputSamplingFrequency: outputSamplingFrequency = child.float
            case MatroskaID.channels: channels = max(child.int ?? 1, 1)
            case MatroskaID.bitDepth: bitDepth = child.int
            default: break
            }
        }
    }

    /// Header stripping is undone by the demuxer; any other compression, and encryption, mark the track unusable.
    /// Encodings that apply only to CodecPrivate (ContentEncodingScope bit 2 without bit 1) don't touch the frames.
    private mutating func applyEncodings(_ payload: UnsafeBufferPointer<UInt8>) {
        for encoding in EBMLChildren(payload) where encoding.id == MatroskaID.contentEncoding {
            var scope: UInt64 = 1
            var type: UInt64 = 0
            var algorithm: UInt64?
            var settings = Data()
            for child in EBMLChildren(encoding.payload) {
                switch child.id {
                case MatroskaID.contentEncodingScope: scope = child.unsigned ?? 1
                case MatroskaID.contentEncodingType: type = child.unsigned ?? 0
                case MatroskaID.contentCompression:
                    algorithm = 0
                    for setting in EBMLChildren(child.payload) {
                        if setting.id == MatroskaID.contentCompAlgo { algorithm = setting.unsigned ?? 0 }
                        if setting.id == MatroskaID.contentCompSettings { settings = setting.data }
                    }
                case MatroskaID.contentEncryption: type = 1
                default: break
                }
            }
            guard (scope & 1) != 0 else { continue }
            if type == 0, algorithm == 3 {
                strippedHeader = (strippedHeader ?? Data()) + settings
            } else {
                hasUnsupportedEncoding = true
            }
        }
    }
}
