//
//  MatroskaTestWriter.swift
//  MatroskaTestSupport
//
//  Writes small Matroska streams for the tests: an EBML header, a Segment with a SeekHead, Info and Tracks, one
//  Cluster per video keyframe (or per audio run when there is no video) holding SimpleBlocks, and Cues before or
//  after the Clusters. Element IDs are spelled out here rather than taken from the demuxer, so the tests check the
//  demuxer against the specification, not against itself.
//

import Foundation

public enum EBMLWriter {
    /// An element ID's bytes (its length marker is part of the value).
    public static func idBytes(_ id: UInt32) -> [UInt8] {
        let bytes = withUnsafeBytes(of: id.bigEndian, Array.init)
        return Array(bytes.drop { $0 == 0 })
    }

    /// A size as a variable-length integer, in `width` bytes (the shortest that fits by default).
    public static func size(_ value: Int, width: Int? = nil) -> [UInt8] {
        let length = width ?? (1...8).first { value < (1 << (7 * $0)) - 1 } ?? 8
        var bytes = (0..<length).map { UInt8(truncatingIfNeeded: value >> (8 * (length - 1 - $0))) }
        bytes[0] |= UInt8(0x80) >> (length - 1)
        return bytes
    }

    /// The reserved all-ones size: unknown.
    public static let unknownSize: [UInt8] = [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]

    public static func element(_ id: UInt32, _ payload: [UInt8]) -> [UInt8] {
        idBytes(id) + size(payload.count) + payload
    }

    public static func uint(_ id: UInt32, _ value: UInt64, width: Int? = nil) -> [UInt8] {
        let length = width ?? max(1, (UInt64.bitWidth - value.leadingZeroBitCount + 7) / 8)
        return element(id, (0..<length).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64(length - 1 - $0))) })
    }

    public static func string(_ id: UInt32, _ value: String) -> [UInt8] {
        element(id, Array(value.utf8))
    }

    public static func float(_ id: UInt32, _ value: Double) -> [UInt8] {
        uint(id, value.bitPattern, width: 8)
    }

    /// A SimpleBlock (or Block) payload: track, relative timestamp, flags, then the data.
    public static func blockPayload(track: UInt64, relative: Int16, flags: UInt8, data: [UInt8]) -> [UInt8] {
        size(Int(track)) + [UInt8(truncatingIfNeeded: relative >> 8), UInt8(truncatingIfNeeded: relative), flags]
            + data
    }
}

/// IDs from RFC 9559, for the writer.
public enum MatroskaTestID {
    public static let ebml: UInt32 = 0x1A45DFA3
    public static let docType: UInt32 = 0x4282
    public static let segment: UInt32 = 0x18538067
    public static let seekHead: UInt32 = 0x114D9B74
    public static let seek: UInt32 = 0x4DBB
    public static let seekID: UInt32 = 0x53AB
    public static let seekPosition: UInt32 = 0x53AC
    public static let info: UInt32 = 0x1549A966
    public static let timestampScale: UInt32 = 0x2AD7B1
    public static let duration: UInt32 = 0x4489
    public static let tracks: UInt32 = 0x1654AE6B
    public static let trackEntry: UInt32 = 0xAE
    public static let trackNumber: UInt32 = 0xD7
    public static let trackType: UInt32 = 0x83
    public static let flagDefault: UInt32 = 0x88
    public static let defaultDuration: UInt32 = 0x23E383
    public static let language: UInt32 = 0x22B59C
    public static let codecID: UInt32 = 0x86
    public static let codecPrivate: UInt32 = 0x63A2
    public static let video: UInt32 = 0xE0
    public static let pixelWidth: UInt32 = 0xB0
    public static let pixelHeight: UInt32 = 0xBA
    public static let audio: UInt32 = 0xE1
    public static let samplingFrequency: UInt32 = 0xB5
    public static let channels: UInt32 = 0x9F
    public static let cues: UInt32 = 0x1C53BB6B
    public static let cuePoint: UInt32 = 0xBB
    public static let cueTime: UInt32 = 0xB3
    public static let cueTrackPositions: UInt32 = 0xB7
    public static let cueTrack: UInt32 = 0xF7
    public static let cueClusterPosition: UInt32 = 0xF1
    public static let cluster: UInt32 = 0x1F43B675
    public static let timestamp: UInt32 = 0xE7
    public static let simpleBlock: UInt32 = 0xA3
    public static let blockGroup: UInt32 = 0xA0
    public static let block: UInt32 = 0xA1
    public static let blockDuration: UInt32 = 0x9B
    public static let referenceBlock: UInt32 = 0xFB
    public static let attachments: UInt32 = 0x1941A469
    public static let void: UInt32 = 0xEC
}

public struct MatroskaTestTrack: Sendable {
    public var number: UInt64
    /// 1 video, 2 audio.
    public var type: UInt64
    public var codecID: String
    public var codecPrivate: [UInt8]
    public var language: String?
    public var isDefault = true
    /// Nanoseconds per frame.
    public var defaultDuration: UInt64?
    public var width = 320
    public var height = 240
    public var sampleRate = 48_000.0
    public var channels = 2

    public init(number: UInt64, type: UInt64, codecID: String, codecPrivate: [UInt8] = [], language: String? = nil) {
        self.number = number
        self.type = type
        self.codecID = codecID
        self.codecPrivate = codecPrivate
        self.language = language
    }

    var entry: [UInt8] {
        typealias IDs = MatroskaTestID
        var body = EBMLWriter.uint(IDs.trackNumber, number) + EBMLWriter.uint(IDs.trackType, type)
            + EBMLWriter.string(IDs.codecID, codecID) + EBMLWriter.uint(IDs.flagDefault, isDefault ? 1 : 0)
        if !codecPrivate.isEmpty { body += EBMLWriter.element(IDs.codecPrivate, codecPrivate) }
        if let language { body += EBMLWriter.string(IDs.language, language) }
        if let defaultDuration { body += EBMLWriter.uint(IDs.defaultDuration, defaultDuration) }
        if type == 1 {
            body += EBMLWriter.element(IDs.video, EBMLWriter.uint(IDs.pixelWidth, UInt64(width))
                + EBMLWriter.uint(IDs.pixelHeight, UInt64(height)))
        } else if type == 2 {
            body += EBMLWriter.element(IDs.audio, EBMLWriter.float(IDs.samplingFrequency, sampleRate)
                + EBMLWriter.uint(IDs.channels, UInt64(channels)))
        }
        return EBMLWriter.element(IDs.trackEntry, body)
    }
}

public struct MatroskaTestFrame: Sendable, Equatable {
    public var track: UInt64
    /// Milliseconds (the default TimestampScale).
    public var timestamp: Int64
    public var isKeyframe: Bool
    public var data: [UInt8]

    public init(track: UInt64, timestamp: Int64, isKeyframe: Bool, data: [UInt8]) {
        self.track = track
        self.timestamp = timestamp
        self.isKeyframe = isKeyframe
        self.data = data
    }
}
