//
//  MatroskaSegment.swift
//  Matroska
//
//  What a Segment says about itself before its first Cluster: its Info (timestamp scale, duration, title), its
//  Tracks, and where its SeekHead says the Cues are. Positions in a Segment are relative to the start of its payload;
//  the ones here are absolute offsets in the stream.
//

import Foundation

/// A Segment's Info element.
nonisolated public struct MatroskaSegmentInfo: Sendable, Equatable {
    /// Nanoseconds per timestamp unit (TimestampScale; 1 ms by default).
    public var timestampScale: UInt64 = 1_000_000
    /// The Segment's length in timestamp units (a float in the file).
    public var duration: Double?
    public var title: String?

    public init(timestampScale: UInt64 = 1_000_000, duration: Double? = nil, title: String? = nil) {
        self.timestampScale = timestampScale
        self.duration = duration
        self.title = title
    }

    /// The duration in seconds, when the file gives a plausible one.
    public var durationSeconds: Double? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        let seconds = duration * Double(timestampScale) / 1e9
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    static func parse(_ payload: UnsafeBufferPointer<UInt8>) -> MatroskaSegmentInfo {
        var info = MatroskaSegmentInfo()
        for child in EBMLChildren(payload) {
            switch child.id {
            case MatroskaID.timestampScale:
                if let scale = child.unsigned, scale > 0 { info.timestampScale = scale }
            case MatroskaID.duration:
                info.duration = child.float
            case MatroskaID.title:
                info.title = child.string
            default:
                break
            }
        }
        return info
    }
}

/// Everything known about a Segment when its first Cluster begins.
nonisolated public struct MatroskaSegment: Sendable, Equatable {
    public var info: MatroskaSegmentInfo
    public var tracks: [MatroskaTrack]
    /// The absolute offset of the Segment's payload: SeekHead and Cues positions count from here.
    public var dataOffset: Int64
    /// The payload's size, or nil when the Segment's size is unknown (a file written while streaming).
    public var dataSize: Int64?
    /// Where the Cues are (absolute), from the SeekHead, when they weren't read already.
    public var cuesOffset: Int64?
    /// The first Cluster's absolute offset.
    public var firstClusterOffset: Int64

    public init(info: MatroskaSegmentInfo, tracks: [MatroskaTrack], dataOffset: Int64, dataSize: Int64?,
                cuesOffset: Int64?, firstClusterOffset: Int64) {
        self.info = info
        self.tracks = tracks
        self.dataOffset = dataOffset
        self.dataSize = dataSize
        self.cuesOffset = cuesOffset
        self.firstClusterOffset = firstClusterOffset
    }

    /// The absolute offset where the Segment ends, when its size is known.
    public var endOffset: Int64? { dataSize.map { dataOffset + $0 } }

    public func track(_ number: UInt64) -> MatroskaTrack? {
        tracks.first { $0.number == number }
    }

    /// Nanoseconds for `timestamp` timestamp units, saturating rather than overflowing.
    public func nanoseconds(_ timestamp: Int64) -> Int64 {
        let product = Int128(timestamp) * Int128(info.timestampScale)
        return Int64(clamping: product)
    }

    /// 90 kHz ticks for `timestamp` timestamp units (the clock the decoders and renderers use).
    public func ticks(_ timestamp: Int64) -> Int64 {
        let product = Int128(timestamp) * Int128(info.timestampScale) * 9 / 100_000
        return Int64(clamping: product)
    }

    /// Timestamp units for a time in 90 kHz ticks, rounded down.
    public func timestamp(ticks: Int64) -> Int64 {
        let product = Int128(ticks) * 100_000 / (9 * Int128(info.timestampScale))
        return Int64(clamping: product)
    }
}

nonisolated enum MatroskaSeekHead {
    /// SeekPosition by SeekID: where (relative to the Segment's payload) each listed element is.
    static func positions(in payload: UnsafeBufferPointer<UInt8>) -> [UInt32: UInt64] {
        var positions: [UInt32: UInt64] = [:]
        for seek in EBMLChildren(payload) where seek.id == MatroskaID.seek {
            var id: UInt32?
            var position: UInt64?
            for child in EBMLChildren(seek.payload) {
                if child.id == MatroskaID.seekID, child.payload.count <= 4 {
                    id = child.unsigned.map { UInt32(truncatingIfNeeded: $0) }
                }
                if child.id == MatroskaID.seekPosition { position = child.unsigned }
            }
            // The first entry for an ID wins (later ones point at duplicates).
            if let id, let position, positions[id] == nil { positions[id] = position }
            if positions.count >= 64 { break }
        }
        return positions
    }
}

/// The EBML header's DocType.
nonisolated enum MatroskaDocType {
    static let accepted: Set<String> = ["matroska", "webm"]

    static func docType(in payload: UnsafeBufferPointer<UInt8>) -> String? {
        EBMLChildren(payload).first { $0.id == MatroskaID.docType }?.string
    }
}
