//
//  DemuxerTests.swift
//  MatroskaTests
//
//  The streaming demuxer on synthetic files: the Segment's header, blocks in any chunking, Cues in front or found
//  through the SeekHead, unknown sizes, restarting at a Cluster, and finding its feet again after damage.
//

import Foundation
@testable import Matroska
import MatroskaTestSupport
import Testing

/// What a demuxer emitted, with block payloads copied.
struct DemuxLog {
    struct Frame: Equatable {
        var track: UInt64
        var timestamp: Int64
        var isKeyframe: Bool
        var data: [UInt8]
    }

    var segment: MatroskaSegment?
    var cues: MatroskaCues?
    var frames: [Frame] = []
    var demuxer: MatroskaDemuxer

    init(_ demuxer: MatroskaDemuxer = MatroskaDemuxer()) {
        self.demuxer = demuxer
    }

    /// Feeds `bytes` (starting at `offset` of the stream) in `chunk`-byte pieces.
    mutating func feed(_ bytes: [UInt8], chunk: Int, from offset: Int = 0) {
        var position = offset
        while position < bytes.count {
            let end = min(position + chunk, bytes.count)
            bytes[position..<end].withUnsafeBytes { raw in
                demuxer.feed(raw) { event in
                    switch event {
                    case .segment(let found): segment = found
                    case .cues(let found): cues = found
                    case .block(let block, let payload):
                        for range in block.frames {
                            frames.append(Frame(track: block.track, timestamp: block.timestamp,
                                                isKeyframe: block.isKeyframe, data: Array(payload[range])))
                        }
                    }
                }
            }
            position = end
        }
    }

    static func demux(_ bytes: [UInt8], chunk: Int = 1 << 20) -> DemuxLog {
        var log = DemuxLog()
        log.feed(bytes, chunk: chunk)
        return log
    }
}

enum DemuxFixture {
    static let video = {
        var track = MatroskaTestTrack(number: 1, type: 1, codecID: "V_MPEG4/ISO/AVC", codecPrivate: [1, 2, 3])
        track.defaultDuration = 40_000_000
        track.width = 1280
        track.height = 720
        return track
    }()

    static let audio = {
        var track = MatroskaTestTrack(number: 2, type: 2, codecID: "A_AC3", language: "spa")
        track.isDefault = false
        track.channels = 6
        return track
    }()

    /// Three Clusters of 25 video frames (one keyframe each, 40 ms apart) with an audio frame every 32 ms.
    static func frames() -> [MatroskaTestFrame] {
        var frames: [MatroskaTestFrame] = []
        for index in 0..<75 {
            let time = Int64(index * 40)
            frames.append(MatroskaTestFrame(track: 1, timestamp: time, isKeyframe: index % 25 == 0,
                                            data: [UInt8](repeating: UInt8(index), count: 100 + index)))
            if index % 4 == 0 {
                frames.append(MatroskaTestFrame(track: 2, timestamp: time + 2, isKeyframe: true,
                                                data: [0x0B, 0x77, UInt8(index)]))
            }
        }
        return frames
    }

    static func file(cues: MatroskaTestFile.CuesPlacement = .end, unknownSizes: Bool = false) -> MatroskaTestFile {
        var file = MatroskaTestFile(tracks: [video, audio], frames: frames(), durationMilliseconds: 3_000)
        file.cues = cues
        file.unknownSizes = unknownSizes
        file.write()
        return file
    }

    static func expected(_ frames: [MatroskaTestFrame]) -> [DemuxLog.Frame] {
        frames.map { frame in
            DemuxLog.Frame(track: frame.track, timestamp: frame.timestamp, isKeyframe: frame.isKeyframe,
                           data: frame.data)
        }
    }
}

struct DemuxerTests {
    @Test func readsTheSegmentHeader() throws {
        let file = DemuxFixture.file()
        let log = DemuxLog.demux(file.bytes)
        let segment = try #require(log.segment)
        #expect(log.demuxer.failure == nil)
        #expect(segment.info.timestampScale == 1_000_000)
        #expect(segment.info.durationSeconds == 3)
        #expect(segment.tracks.map(\.codecID) == ["V_MPEG4/ISO/AVC", "A_AC3"])
        let video = try #require(segment.track(1))
        #expect(video.kind == .video && video.codecPrivate == Data([1, 2, 3]))
        #expect(video.pixelWidth == 1280 && video.pixelHeight == 720 && video.defaultDuration == 40_000_000)
        #expect(video.language == "eng" && video.isDefault)
        let audio = try #require(segment.track(2))
        #expect(audio.kind == .audio && audio.language == "spa" && !audio.isDefault)
        #expect(audio.samplingFrequency == 48_000 && audio.channels == 6)
        #expect(segment.firstClusterOffset == Int64(file.clusters[0].offset))
        // The Cues are after the Clusters: the SeekHead says where, and reading on reaches them too.
        #expect(log.cues?.points.count == 3)
        let cuesOffset = try #require(segment.cuesOffset)
        #expect(cuesOffset > Int64(file.clusters[2].offset))
    }

    @Test func everyChunkingGivesTheSameBlocks() {
        let file = DemuxFixture.file()
        let expected = DemuxFixture.expected(file.frames)
        for chunk in [1, 2, 3, 7, 64, 1_000, 4_096, file.bytes.count] {
            let log = DemuxLog.demux(file.bytes, chunk: chunk)
            #expect(log.frames == expected, "chunk \(chunk)")
            #expect(log.demuxer.statistics.resynchronizations == 0)
        }
    }

    @Test func cuesInFrontAreHandedOn() throws {
        let file = DemuxFixture.file(cues: .front)
        let log = DemuxLog.demux(file.bytes, chunk: 100)
        let cues = try #require(log.cues)
        #expect(cues.points.map(\.clusterOffset) == file.clusters.map { Int64($0.offset) })
        #expect(cues.points.map(\.time) == [0, 1_000, 2_000])
        #expect(log.segment?.cuesOffset == nil)
        #expect(log.frames == DemuxFixture.expected(file.frames))
    }

    @Test func cuesAreReadWhereTheSeekHeadPoints() throws {
        let file = DemuxFixture.file()
        let segment = try #require(DemuxLog.demux(file.bytes).segment)
        let offset = try #require(segment.cuesOffset)
        var log = DemuxLog(MatroskaDemuxer(continuing: segment, at: offset, atElement: true))
        log.feed(file.bytes, chunk: 50, from: Int(offset))
        #expect(log.cues?.points.map(\.clusterOffset) == file.clusters.map { Int64($0.offset) })
    }

    @Test func unknownSizesAreFollowed() {
        let file = DemuxFixture.file(unknownSizes: true)
        for chunk in [5, 4_096] {
            let log = DemuxLog.demux(file.bytes, chunk: chunk)
            #expect(log.segment?.dataSize == nil)
            #expect(log.frames == DemuxFixture.expected(file.frames))
            #expect(log.demuxer.statistics.resynchronizations == 0)
        }
    }

    @Test func restartingAtAClusterReadsFromThere() throws {
        let file = DemuxFixture.file()
        var log = DemuxLog()
        // The header is announced once the first Cluster begins.
        log.feed(Array(file.bytes[..<(file.clusters[0].offset + 16)]), chunk: 1 << 20)
        #expect(log.segment != nil)
        let second = file.clusters[1]
        log.demuxer.restart(at: Int64(second.offset), atElement: true)
        log.feed(file.bytes, chunk: 333, from: second.offset)
        #expect(log.frames.first?.timestamp == second.timestamp)
        #expect(log.frames.first?.isKeyframe == true)
        #expect(log.frames == DemuxFixture.expected(file.frames.filter { $0.timestamp >= second.timestamp }))
    }

    @Test func restartingAnywhereSearchesForTheNextCluster() throws {
        let file = DemuxFixture.file()
        let segment = try #require(DemuxLog.demux(file.bytes).segment)
        let middle = file.clusters[0].offset + 500
        var log = DemuxLog(MatroskaDemuxer(continuing: segment, at: Int64(middle), atElement: false))
        log.feed(file.bytes, chunk: 97, from: middle)
        #expect(log.frames.first?.timestamp == file.clusters[1].timestamp)
        #expect(log.frames.last?.timestamp == file.frames.last?.timestamp)
    }

    @Test func damageInAClusterIsSkippedToTheNextOne() {
        let file = DemuxFixture.file()
        var bytes = file.bytes
        // Wreck the second Cluster's first SimpleBlock header (after the Cluster's ID and size, and its Timestamp):
        // no element ID starts with a zero byte.
        let cluster = file.clusters[1].offset
        let sizeLength = bytes[cluster + 4].leadingZeroBitCount + 1
        let timestampLength = 2 + Int(bytes[cluster + 4 + sizeLength + 1] & 0x7F)
        let block = cluster + 4 + sizeLength + timestampLength
        #expect(bytes[block] == 0xA3)
        bytes[block] = 0x00
        let log = DemuxLog.demux(bytes, chunk: 1_000)
        #expect(log.demuxer.failure == nil)
        #expect(log.demuxer.statistics.resynchronizations >= 1)
        let third = file.clusters[2].timestamp
        #expect(log.frames.contains { $0.timestamp == third && $0.isKeyframe })
        #expect(log.frames.last == DemuxFixture.expected(file.frames).last)
    }
}
