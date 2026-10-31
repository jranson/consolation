//
//  MatroskaTestFile.swift
//  MatroskaTestSupport
//
//  A whole synthetic Matroska file from tracks and frames (see MatroskaTestWriter.swift).
//

import Foundation

public struct MatroskaTestFile: Sendable {
    public enum CuesPlacement: Sendable {
        case none
        /// Before the Clusters (as mkvmerge does with `--cues` up front).
        case front
        /// After the Clusters, with the SeekHead pointing at them (the usual layout).
        case end
    }

    public var tracks: [MatroskaTestTrack]
    public var frames: [MatroskaTestFrame]
    public var durationMilliseconds: Double?
    public var cues = CuesPlacement.end
    /// Segment and Clusters of unknown size, as a file written while streaming.
    public var unknownSizes = false
    /// An Attachments element of this many bytes before the Clusters.
    public var attachmentBytes = 0
    public var docType = "matroska"

    /// The written file, and each Cluster's absolute offset and timestamp.
    public private(set) var bytes: [UInt8] = []
    public private(set) var clusters: [(offset: Int, timestamp: Int64)] = []

    public init(tracks: [MatroskaTestTrack], frames: [MatroskaTestFrame], durationMilliseconds: Double? = nil) {
        self.tracks = tracks
        self.frames = frames
        self.durationMilliseconds = durationMilliseconds
    }

    public var data: Data { Data(bytes) }

    /// Writes the file into `bytes` and `clusters`.
    public mutating func write() {
        typealias IDs = MatroskaTestID
        let header = EBMLWriter.element(IDs.ebml, EBMLWriter.string(IDs.docType, docType))
        var info = EBMLWriter.uint(IDs.timestampScale, 1_000_000)
        if let durationMilliseconds { info += EBMLWriter.float(IDs.duration, durationMilliseconds) }
        let infoElement = EBMLWriter.element(IDs.info, info)
        let tracksElement = EBMLWriter.element(IDs.tracks, tracks.flatMap(\.entry))
        let attachments = attachmentBytes > 0
            ? EBMLWriter.element(IDs.attachments, [UInt8](repeating: 0x5A, count: attachmentBytes)) : []
        let clusterElements = clusterGroups().map(cluster)
        // Positions are written eight bytes wide, so the SeekHead and Cues sizes don't depend on them.
        let seekHeadLength = seekHead(cues: 0).count
        let cuesLength = cuesElement(offsets: Array(repeating: 0, count: clusterElements.count)).count
        let beforeClusters = seekHeadLength + infoElement.count + tracksElement.count + attachments.count
            + (cues == .front ? cuesLength : 0)
        var position = beforeClusters
        var relative: [Int] = []
        for element in clusterElements {
            relative.append(position)
            position += element.bytes.count
        }
        let cuesPosition = cues == .front ? beforeClusters - cuesLength : position
        var body = seekHead(cues: cues == .none ? nil : cuesPosition) + infoElement + tracksElement + attachments
        let cuesBytes = cuesElement(offsets: relative)
        if cues == .front { body += cuesBytes }
        body += clusterElements.flatMap(\.bytes)
        if cues == .end { body += cuesBytes }
        let segmentHeader = EBMLWriter.idBytes(IDs.segment)
            + (unknownSizes ? EBMLWriter.unknownSize : EBMLWriter.size(body.count, width: 8))
        bytes = header + segmentHeader + body
        let dataStart = header.count + segmentHeader.count
        clusters = zip(relative, clusterElements).map { (dataStart + $0, $1.timestamp) }
    }

    /// Frames grouped into Clusters: a new one at every video keyframe (every eighth frame without video).
    private func clusterGroups() -> [[MatroskaTestFrame]] {
        let videoTracks = Set(tracks.filter { $0.type == 1 }.map(\.number))
        var groups: [[MatroskaTestFrame]] = []
        for (index, frame) in frames.enumerated() {
            let starts = videoTracks.isEmpty ? index % 8 == 0 : (videoTracks.contains(frame.track) && frame.isKeyframe)
            if starts || groups.isEmpty { groups.append([]) }
            groups[groups.count - 1].append(frame)
        }
        return groups
    }

    private func cluster(_ frames: [MatroskaTestFrame]) -> (bytes: [UInt8], timestamp: Int64) {
        typealias IDs = MatroskaTestID
        let timestamp = frames.map(\.timestamp).min() ?? 0
        var body = EBMLWriter.uint(IDs.timestamp, UInt64(max(timestamp, 0)))
        for frame in frames {
            let relative = Int16(clamping: frame.timestamp - timestamp)
            body += EBMLWriter.element(IDs.simpleBlock, EBMLWriter.blockPayload(
                track: frame.track, relative: relative, flags: frame.isKeyframe ? 0x80 : 0, data: frame.data))
        }
        let header = EBMLWriter.idBytes(IDs.cluster)
            + (unknownSizes ? EBMLWriter.unknownSize : EBMLWriter.size(body.count))
        return (header + body, timestamp)
    }

    private func seekHead(cues position: Int?) -> [UInt8] {
        typealias IDs = MatroskaTestID
        // Always the same size: an absent Cues entry is replaced by a Void of equal length.
        let entry = EBMLWriter.element(IDs.seek, EBMLWriter.element(IDs.seekID, EBMLWriter.idBytes(IDs.cues))
            + EBMLWriter.uint(IDs.seekPosition, UInt64(position ?? 0), width: 8))
        let filler = EBMLWriter.idBytes(IDs.void) + EBMLWriter.size(entry.count - 2, width: 1)
            + [UInt8](repeating: 0, count: entry.count - 2)
        return EBMLWriter.element(IDs.seekHead, position == nil ? filler : entry)
    }

    /// One CuePoint per Cluster, for the first video track (or the first track).
    private func cuesElement(offsets: [Int]) -> [UInt8] {
        typealias IDs = MatroskaTestID
        let track = tracks.first { $0.type == 1 }?.number ?? tracks.first?.number ?? 1
        let groups = clusterGroups()
        var points: [UInt8] = []
        for (index, offset) in offsets.enumerated() {
            let time = groups.indices.contains(index) ? groups[index].map(\.timestamp).min() ?? 0 : 0
            let positions = EBMLWriter.uint(IDs.cueTrack, track, width: 8)
                + EBMLWriter.uint(IDs.cueClusterPosition, UInt64(offset), width: 8)
            points += EBMLWriter.element(IDs.cuePoint, EBMLWriter.uint(IDs.cueTime, UInt64(max(time, 0)), width: 8)
                + EBMLWriter.element(IDs.cueTrackPositions, positions))
        }
        return EBMLWriter.element(IDs.cues, points)
    }
}
