//
//  MatroskaID.swift
//  Matroska
//
//  The element IDs this demuxer reads (RFC 9559), with their length markers, as the specification writes them.
//

nonisolated enum MatroskaID {
    // EBML header
    static let ebml: UInt32 = 0x1A45DFA3
    static let docType: UInt32 = 0x4282

    // Top level and Segment children
    static let segment: UInt32 = 0x18538067
    static let seekHead: UInt32 = 0x114D9B74
    static let info: UInt32 = 0x1549A966
    static let tracks: UInt32 = 0x1654AE6B
    static let cues: UInt32 = 0x1C53BB6B
    static let cluster: UInt32 = 0x1F43B675
    static let chapters: UInt32 = 0x1043A770
    static let tags: UInt32 = 0x1254C367
    static let attachments: UInt32 = 0x1941A469

    // Global
    static let void: UInt32 = 0xEC
    static let crc32: UInt32 = 0xBF

    // SeekHead
    static let seek: UInt32 = 0x4DBB
    static let seekID: UInt32 = 0x53AB
    static let seekPosition: UInt32 = 0x53AC

    // Info
    static let timestampScale: UInt32 = 0x2AD7B1
    static let duration: UInt32 = 0x4489
    static let title: UInt32 = 0x7BA9

    // Tracks
    static let trackEntry: UInt32 = 0xAE
    static let trackNumber: UInt32 = 0xD7
    static let trackType: UInt32 = 0x83
    static let flagEnabled: UInt32 = 0xB9
    static let flagDefault: UInt32 = 0x88
    static let flagForced: UInt32 = 0x55AA
    static let defaultDuration: UInt32 = 0x23E383
    static let name: UInt32 = 0x536E
    static let language: UInt32 = 0x22B59C
    static let languageBCP47: UInt32 = 0x22B59D
    static let codecID: UInt32 = 0x86
    static let codecPrivate: UInt32 = 0x63A2
    static let codecDelay: UInt32 = 0x56AA
    static let video: UInt32 = 0xE0
    static let audio: UInt32 = 0xE1
    static let contentEncodings: UInt32 = 0x6D80

    // Video
    static let pixelWidth: UInt32 = 0xB0
    static let pixelHeight: UInt32 = 0xBA
    static let displayWidth: UInt32 = 0x54B0
    static let displayHeight: UInt32 = 0x54BA
    static let flagInterlaced: UInt32 = 0x9A
    static let fieldOrder: UInt32 = 0x9D

    // Audio
    static let samplingFrequency: UInt32 = 0xB5
    static let outputSamplingFrequency: UInt32 = 0x78B5
    static let channels: UInt32 = 0x9F
    static let bitDepth: UInt32 = 0x6264

    // ContentEncodings
    static let contentEncoding: UInt32 = 0x6240
    static let contentEncodingScope: UInt32 = 0x5032
    static let contentEncodingType: UInt32 = 0x5033
    static let contentCompression: UInt32 = 0x5034
    static let contentCompAlgo: UInt32 = 0x4254
    static let contentCompSettings: UInt32 = 0x4255
    static let contentEncryption: UInt32 = 0x5035

    // Cues
    static let cuePoint: UInt32 = 0xBB
    static let cueTime: UInt32 = 0xB3
    static let cueTrackPositions: UInt32 = 0xB7
    static let cueTrack: UInt32 = 0xF7
    static let cueClusterPosition: UInt32 = 0xF1
    static let cueRelativePosition: UInt32 = 0xF0

    // Cluster
    static let timestamp: UInt32 = 0xE7
    static let simpleBlock: UInt32 = 0xA3
    static let blockGroup: UInt32 = 0xA0
    static let block: UInt32 = 0xA1
    static let blockDuration: UInt32 = 0x9B
    static let referenceBlock: UInt32 = 0xFB

    /// Elements that may sit directly in a Segment: one of these ends a Cluster of unknown size.
    static let segmentChildren: Set<UInt32> = [
        seekHead, info, tracks, cues, cluster, chapters, tags, attachments
    ]
}
