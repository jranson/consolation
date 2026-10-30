//
//  TimeShiftIndexTests.swift
//  PlaybackKitTests
//
//  The time-shift index on its own: points from the ingest (and from data that arrived before the PMT), seek
//  points at random-access pictures, a live clock that steps over timestamp jumps, a file clock that survives a
//  reopen, and points dropped as the ring overwrites their data. Also the timeline value's arithmetic.
//

import Foundation
import MPEGTS
@testable import PlaybackKit
import Testing

#if os(macOS)
nonisolated struct TimeShiftIndexTests {
    /// Appends `data` to `ring` in `chunk`-byte pieces, indexing each; the PMT is "read" after the first piece.
    private static func fill(_ index: TimeShiftIndex, ring: MemoryByteRing, with data: Data, chunk: Int = 50_000,
                             selectAfterFirst: Bool = true) {
        var offset = 0
        while offset < data.count {
            let piece = data.subdata(in: offset..<min(offset + chunk, data.count))
            let start = ring.writeHead
            ring.append(piece)
            index.ingest(piece, at: start, oldest: ring.oldestOffset, generation: 0)
            if offset == 0, selectAfterFirst {
                index.selectVideo(pid: SyntheticNALStream.videoPID, kind: .h264, ring: ring)
            }
            offset += chunk
        }
    }

    @Test func indexesTheStreamIncludingWhatArrivedBeforeThePMT() throws {
        let data = try #require(TimeShiftStream.tenSeconds)
        let index = TimeShiftIndex()
        let ring = MemoryByteRing(capacity: 8 << 20)
        Self.fill(index, ring: ring, with: data)
        let window = try #require(index.window(from: ring.oldestOffset))
        #expect(window.lowerBound == 0)
        #expect(abs(window.upperBound - TimeShiftStream.lastPicture(of: 300)) < 0.001)
        // Every half-second keyframe is a seek point.
        for target in [0.0, 2.2, 6.0, 9.9] {
            let point = try #require(index.seekPoint(for: target, from: ring.oldestOffset))
            #expect(point.isRandomAccess)
            #expect(point.time <= target + 0.001)
            #expect(target - point.time < 0.5 + TimeShiftStream.frameSeconds)
            #expect(point.pts == TimeShiftStream.pts(at: point.time))
        }
        let rate = try #require(index.bytesPerSecond)
        #expect(abs(rate - Double(data.count) / 10) / rate < 0.2)
        #expect(index.time(ofPTS: TimeShiftStream.pts(at: 4.0), near: Int64(data.count / 2)).map { abs($0 - 4) < 0.001 }
                == true)
    }

    /// A live stream whose timestamps jump an hour ahead (a splice) keeps a continuous clock: twenty seconds, not
    /// an hour.
    @Test func aLiveClockStepsOverATimestampJump() throws {
        let first = try #require(TimeShiftStream.tenSeconds)
        let second = try #require(TimeShiftStream.make(frames: 300, shift: 3_600 * 90_000))
        let index = TimeShiftIndex()
        let ring = MemoryByteRing(capacity: 8 << 20)
        Self.fill(index, ring: ring, with: first + second)
        let window = try #require(index.window(from: ring.oldestOffset))
        #expect(abs(window.upperBound - (2 * TimeShiftStream.lastPicture(of: 300) + 1.0 / 30)) < 0.01)
        let point = try #require(index.seekPoint(for: 15, from: ring.oldestOffset))
        #expect(point.offset >= Int64(first.count))
        #expect(point.pts > 3_600 * 90_000)
    }

    /// Points whose data the ring overwrote are dropped: the window's start moves up with the ring's oldest byte.
    @Test func ringEvictionMovesTheLowerBound() throws {
        let data = try #require(TimeShiftStream.tenSeconds)
        let index = TimeShiftIndex()
        let ring = MemoryByteRing(capacity: data.count / 2, minimum: 188)
        Self.fill(index, ring: ring, with: data)
        let window = try #require(index.window(from: ring.oldestOffset))
        #expect(window.lowerBound > 3.5 && window.lowerBound < 6.5)
        #expect(abs(window.upperBound - TimeShiftStream.lastPicture(of: 300)) < 0.001)
        #expect(index.seekPoint(for: 1, from: ring.oldestOffset).map { $0.offset >= ring.oldestOffset } == true)
    }

    /// When the index starts scanning a file after its beginning (the reader took in more than the ring holds
    /// before it read the PMT), the reader's first picture sets the clock's zero and the times move to match.
    @Test func theReaderSetsAFileClocksZero() throws {
        let data = try #require(TimeShiftStream.tenSeconds)
        let index = TimeShiftIndex()
        index.useFileClock()
        let ring = MemoryByteRing(capacity: data.count / 2, minimum: 188)
        ring.append(data)
        index.selectVideo(pid: SyntheticNALStream.videoPID, kind: .h264, ring: ring)
        let provisional = try #require(index.window(from: ring.oldestOffset))
        #expect(provisional.lowerBound < 1)
        index.confirmFileOrigin(pts: SyntheticNALStream.firstPTS)
        let window = try #require(index.window(from: ring.oldestOffset))
        #expect(window.lowerBound > 3.5)
        #expect(abs(window.upperBound - TimeShiftStream.lastPicture(of: 300)) < 0.001)
        let point = try #require(index.seekPoint(for: 7, from: ring.oldestOffset))
        #expect(point.pts == TimeShiftStream.pts(at: point.time))
    }

    /// A file's clock is its PTS less the first picture's, so a reopen in the middle keeps the same times.
    @Test func aFileClockSurvivesAReopen() throws {
        let data = try #require(TimeShiftStream.tenSeconds)
        let index = TimeShiftIndex()
        index.useFileClock()
        let ring = MemoryByteRing(capacity: 8 << 20)
        Self.fill(index, ring: ring, with: data.subdata(in: 0..<(188 * 1_000)))
        let reopenAt = Int64(data.count / 2 / 188 * 188)
        ring.reset(to: reopenAt)
        index.reset(to: reopenAt, generation: 1)
        #expect(index.window(from: ring.oldestOffset) == nil)
        let rest = data.subdata(in: Int(reopenAt)..<data.count)
        ring.append(rest)
        index.ingest(rest, at: reopenAt, oldest: ring.oldestOffset, generation: 1)
        // A chunk from the old ingest is ignored.
        index.ingest(data.subdata(in: 0..<50_000), at: 0, oldest: 0, generation: 0)
        index.markEnd()
        let window = try #require(index.window(from: ring.oldestOffset))
        #expect(window.lowerBound > 3 && window.lowerBound < 7)
        #expect(abs(window.upperBound - TimeShiftStream.lastPicture(of: 300)) < 0.001)
        #expect(index.duration == window.upperBound)
        let point = try #require(index.seekPoint(for: 8, from: ring.oldestOffset))
        #expect(point.pts == TimeShiftStream.pts(at: point.time))
    }
}
#endif

struct PlaybackTimelineTests {
    @Test func clampsAndMeasures() {
        let timeline = PlaybackTimeline(range: 10...70, position: 85, isLive: false)
        #expect(timeline.position == 70)
        #expect(timeline.duration == 60)
        #expect(timeline.remaining == 0)
        #expect(PlaybackTimeline(range: 10...70, position: -5, isLive: false).position == 10)
        let middle = PlaybackTimeline(range: 10...70, position: 25, isLive: false)
        #expect(middle.elapsed == 15)
        #expect(middle.fraction == 0.25)
        #expect(middle.position(atFraction: 0.5) == 40)
        #expect(middle.position(atFraction: 2) == 70)
        #expect(middle.position(atFraction: -1) == 10)
        #expect(PlaybackTimeline(range: 5...5, position: 5, isLive: true).fraction == 1)
    }

    @Test func liveEdgeTolerance() {
        #expect(PlaybackTimeline(range: 0...100, position: 97, isLive: true).isAtLiveEdge)
        #expect(!PlaybackTimeline(range: 0...100, position: 95, isLive: true).isAtLiveEdge)
        #expect(!PlaybackTimeline(range: 0...100, position: 100, isLive: false).isAtLiveEdge)
    }

    /// The pipeline's snapshot moves on in real time while playing, by at most a second, and not while paused.
    @Test func snapshotsExtrapolateWhilePlaying() {
        let start: UInt64 = 1_000_000_000
        let playing = TimeShiftSnapshot(range: 0...60, position: 10, isPlaying: true, isLive: true, sampledAt: start)
        #expect(playing.timeline(now: start + 250_000_000).position == 10.25)
        #expect(playing.timeline(now: start + 5_000_000_000).position == 11)
        var paused = playing
        paused.isPlaying = false
        #expect(paused.timeline(now: start + 250_000_000).position == 10)
        let box = TimelineBox()
        #expect(box.timeline() == nil)
        box.snapshot = playing
        box.pendingSeek = 42
        #expect(box.timeline(now: start + 250_000_000)?.position == 42)
    }
}
