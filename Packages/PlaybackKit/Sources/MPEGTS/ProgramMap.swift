//
//  ProgramMap.swift
//  MPEGTS
//
//  The program and elementary-stream model built from the PAT and PMTs.
//

/// What an elementary stream carries, from its stream_type and descriptors.
nonisolated public enum StreamKind: Sendable, Hashable {
    /// stream_type 0x02 (ISO/IEC 13818-2).
    case mpeg2Video
    /// stream_type 0x1B.
    case h264
    /// stream_type 0x24.
    case hevc
    /// stream_type 0x81 (ATSC, with or without the `AC-3` registration descriptor), or stream_type 0x06 with the DVB
    /// AC-3 descriptor (0x6A) or an `AC-3` registration descriptor (0x05).
    case ac3
    /// stream_type 0x87 (ATSC), or stream_type 0x06 with the DVB enhanced AC-3 descriptor (0x7A) or `EAC3` registration.
    case eac3
    /// stream_type 0x0F: AAC in ADTS. LATM (0x11) is reported as `.other(0x11)`.
    case aac
    /// stream_type 0x03 or 0x04: MPEG-1/2 audio (MP2/MP3).
    case mpegAudio
    /// Dolby AC-4 (ATSC 3.0 audio): stream_type 0x06 with the DVB AC-4 descriptor (extension descriptor 0x7F,
    /// tag extension 0x15, ETSI EN 300 468 Annex D) or an `AC-4` registration descriptor. No Apple platform decodes
    /// it, so such programs play video only.
    case ac4
    /// Anything else, with its stream_type.
    case other(UInt8)

    public var isVideo: Bool {
        switch self {
        case .mpeg2Video, .h264, .hevc: true
        default: false
        }
    }

    public var isAudio: Bool {
        switch self {
        case .ac3, .eac3, .aac, .mpegAudio, .ac4: true
        default: false
        }
    }
}

/// One elementary stream of a program, as listed in its PMT.
nonisolated public struct ElementaryStream: Sendable, Hashable {
    public var pid: UInt16
    public var streamType: UInt8
    public var kind: StreamKind
    /// The ISO 639-2 code from the first ISO_639_language_descriptor (0x0A), for example "eng" or "spa".
    public var language: String?
    /// The channel count from the ATSC AC-3 audio descriptor (0x81) `num_channels` field: full-bandwidth channels
    /// (LFE is not signalled there), and an upper bound for codes 8–13. Broadcasters often fill it in wrongly, so the
    /// authoritative count is `AC3Frame.channelCount` from the bitstream.
    public var audioChannelsHint: Int?

    public init(
        pid: UInt16,
        streamType: UInt8,
        kind: StreamKind,
        language: String? = nil,
        audioChannelsHint: Int? = nil
    ) {
        self.pid = pid
        self.streamType = streamType
        self.kind = kind
        self.language = language
        self.audioChannelsHint = audioChannelsHint
    }
}

/// A program from the PAT together with its PMT.
nonisolated public struct ProgramMap: Sendable, Hashable {
    public var programNumber: UInt16
    public var pmtPID: UInt16
    public var pcrPID: UInt16
    public var streams: [ElementaryStream]

    public init(programNumber: UInt16, pmtPID: UInt16, pcrPID: UInt16, streams: [ElementaryStream]) {
        self.programNumber = programNumber
        self.pmtPID = pmtPID
        self.pcrPID = pcrPID
        self.streams = streams
    }

    /// The first video stream, if any.
    public var videoStream: ElementaryStream? { streams.first { $0.kind.isVideo } }

    /// The audio streams in PMT order.
    public var audioStreams: [ElementaryStream] { streams.filter { $0.kind.isAudio } }
}
