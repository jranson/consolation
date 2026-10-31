//
//  MatroskaEvent.swift
//  Matroska
//
//  What `MatroskaDemuxer` hands on, why it can stop, and what it counts.
//

import Foundation

nonisolated public enum MatroskaEvent {
    /// The Segment's info and tracks, at its first Cluster.
    case segment(MatroskaSegment)
    /// Cues met in the stream: written before the Clusters, or read where the SeekHead points.
    case cues(MatroskaCues)
    /// One block; its frame ranges index into `payload`, which is valid only during the call.
    case block(MatroskaBlock, payload: UnsafeBufferPointer<UInt8>)
}

nonisolated public enum MatroskaError: Error, Equatable, Sendable {
    /// Not an EBML document, or one whose DocType is neither matroska nor webm.
    case notMatroska
    /// A Cluster began before any usable Tracks.
    case missingTracks
}

nonisolated public struct MatroskaStatistics: Sendable, Equatable {
    public var blocks = 0
    /// Blocks dropped as malformed, too large, or before their Cluster's timestamp.
    public var droppedBlocks = 0
    /// Times the demuxer lost its place and searched for the next Cluster.
    public var resynchronizations = 0

    public init() {}
}
