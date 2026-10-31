//
//  MatroskaCues.swift
//  Matroska
//
//  A Segment's Cues: the seek index. Each CuePoint names a time and, per track, the Cluster that holds the
//  keyframe for it. Writers put the Cues before the Clusters or (more often) after them, with the SeekHead saying
//  where.
//

import Foundation

nonisolated public struct MatroskaCuePoint: Sendable, Equatable {
    /// In timestamp units.
    public var time: Int64
    public var track: UInt64
    /// The Cluster's absolute offset in the stream.
    public var clusterOffset: Int64

    public init(time: Int64, track: UInt64, clusterOffset: Int64) {
        self.time = time
        self.track = track
        self.clusterOffset = clusterOffset
    }
}

nonisolated public struct MatroskaCues: Sendable, Equatable {
    /// Cue points sorted by time (and, for equal times, by position).
    public private(set) var points: [MatroskaCuePoint]

    /// At most this many points are kept (about a keyframe a second for 140 hours).
    static let maximumPoints = 500_000

    public init(points: [MatroskaCuePoint]) {
        self.points = points.sorted { ($0.time, $0.clusterOffset) < ($1.time, $1.clusterOffset) }
    }

    /// The cues of a Cues payload; positions count from `segmentDataOffset`.
    static func parse(_ payload: UnsafeBufferPointer<UInt8>, segmentDataOffset: Int64) -> MatroskaCues {
        var points: [MatroskaCuePoint] = []
        for cue in EBMLChildren(payload) where cue.id == MatroskaID.cuePoint {
            var time: Int64?
            var positions: [(track: UInt64, position: UInt64)] = []
            for child in EBMLChildren(cue.payload) {
                if child.id == MatroskaID.cueTime { time = child.unsigned.flatMap { Int64(exactly: $0) } }
                if child.id == MatroskaID.cueTrackPositions, let entry = trackPosition(child.payload) {
                    positions.append(entry)
                }
            }
            guard let time else { continue }
            for entry in positions {
                guard let relative = Int64(exactly: entry.position) else { continue }
                let (offset, overflow) = segmentDataOffset.addingReportingOverflow(relative)
                if !overflow { points.append(MatroskaCuePoint(time: time, track: entry.track, clusterOffset: offset)) }
            }
            if points.count >= maximumPoints { break }
        }
        return MatroskaCues(points: points)
    }

    private static func trackPosition(_ payload: UnsafeBufferPointer<UInt8>) -> (track: UInt64, position: UInt64)? {
        var track: UInt64?
        var position: UInt64?
        for child in EBMLChildren(payload) {
            if child.id == MatroskaID.cueTrack { track = child.unsigned }
            if child.id == MatroskaID.cueClusterPosition { position = child.unsigned }
        }
        guard let track, let position else { return nil }
        return (track, position)
    }

    public var isEmpty: Bool { points.isEmpty }

    /// The latest cue at or before `time` for `track` (any track's when `track` has none), or the earliest cue when
    /// `time` comes before them all.
    public func point(atOrBefore time: Int64, track: UInt64?) -> MatroskaCuePoint? {
        let candidates = track.map { number in points.filter { $0.track == number } } ?? []
        let list = candidates.isEmpty ? points : candidates
        guard let first = list.first else { return nil }
        // Binary search for the last point with point.time <= time.
        var low = 0
        var high = list.count
        while low < high {
            let middle = (low + high) / 2
            if list[middle].time <= time { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? first : list[low - 1]
    }

    /// The time of the latest cue, a lower bound for the Segment's length when Info gives none.
    public var lastTime: Int64? { points.last?.time }
}
