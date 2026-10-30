//
//  TransportStreamSeekTests.swift
//  PlaybackKitTests
//
//  Seeking in the transport stream pipeline and engine, on H.264 streams encoded here (no network, no tuner): a
//  seek shows the picture at its target (within a picture or two), the live range grows with the ingest and its
//  start follows the ring, files have their whole length (reopening beyond the ring), a paused seek stays paused,
//  and a file that ended plays on after a seek.
//

import AVFoundation
import Foundation
@testable import PlaybackKit
import Testing

#if os(macOS)
@Suite(.serialized)
struct TransportStreamSeekTests {
    private static let pictureTicks = SyntheticNALStream.frameTicks

    /// Waits for the first picture after a seek to `target`, and checks it is the target's (or the next one).
    private static func expectLanding(_ rig: SeekRig, at target: Double) async throws {
        rig.settle()
        #expect(try await eventually { rig.firstPicturePTS != nil })
        let first = try #require(rig.firstPicturePTS)
        let wanted = TimeShiftStream.pts(at: target)
        #expect(first >= wanted - 1 && first - wanted <= 2 * pictureTicks,
                "landed \(Double(first - wanted) / 90_000) s from the target")
    }

    @Test func aLiveSeekLandsOnItsTarget() async throws {
        let data = try #require(await TimeShiftStream.ten())
        let rig = SeekRig(source: FixtureSource(data: data))
        rig.pipeline.start()
        defer { rig.pipeline.stop() }
        #expect(try await eventually { rig.timeline != nil && rig.hasStartedClock })
        let timeline = try #require(rig.timeline)
        #expect(timeline.isLive)
        #expect(timeline.range.lowerBound == 0)
        let lastPicture = TimeShiftStream.lastPicture(of: 300)
        #expect(abs(timeline.range.upperBound - (lastPicture - TransportStreamPipeline.liveEdgeAllowance)) < 0.01)
        for target in [6.0, 2.37] {
            rig.pipeline.seek(toTime: target)
            try await Self.expectLanding(rig, at: target)
            // The position is the target until the clock gets there, then moves on from it.
            let position = try #require(rig.timeline?.position)
            #expect(position >= target - 0.05 && position < target + 1)
        }
        #expect(try await eventually { (rig.timeline?.position ?? 0) > 2.37 + 0.3 })
        #expect(rig.log.failure == nil)
    }

    /// Back and forward from where playback is, as the buttons do.
    @Test func skipsRelativeToThePosition() async throws {
        let data = try #require(await TimeShiftStream.ten())
        let rig = SeekRig(source: FixtureSource(data: data))
        rig.pipeline.start()
        defer { rig.pipeline.stop() }
        #expect(try await eventually { rig.timeline != nil && rig.hasStartedClock })
        rig.pipeline.seek(toTime: 1)
        try await Self.expectLanding(rig, at: 1)
        rig.pipeline.skip(seconds: 4)
        try await Self.expectLanding(rig, at: 5)
        rig.pipeline.skip(seconds: -3.5)
        try await Self.expectLanding(rig, at: 1.5)
    }

    @Test func theLiveRangeGrowsWithTheIngest() async throws {
        let data = try #require(await TimeShiftStream.ten())
        let rig = SeekRig(source: PacedLiveSource(data: data, pieces: 40, seconds: 8))
        rig.pipeline.start()
        defer { rig.pipeline.stop() }
        #expect(try await eventually { (rig.timeline?.range.upperBound ?? 0) > 0.5 })
        let early = try #require(rig.timeline?.range.upperBound)
        #expect(try await eventually { (rig.timeline?.range.upperBound ?? 0) > early + 2 })
        #expect(rig.timeline?.range.lowerBound == 0)
        #expect(rig.timeline?.isAtLiveEdge == true)
    }

    /// A ring half the stream's size holds only its second half: the range covers that, and a seek before it
    /// lands at its start (a live clock starts at the first picture received, here halfway through the stream).
    @Test func theRingsEvictionMovesTheLowerBound() async throws {
        let data = try #require(await TimeShiftStream.ten())
        let rig = SeekRig(source: FixtureSource(data: data), ringBytes: data.count / 2)
        rig.pipeline.start()
        defer { rig.pipeline.stop() }
        #expect(try await eventually { rig.timeline != nil })
        let range = try #require(rig.timeline?.range)
        let held = range.upperBound + TransportStreamPipeline.liveEdgeAllowance - range.lowerBound
        #expect(held > 3 && held < 6.5)
        rig.pipeline.seek(toTime: range.lowerBound - 10)
        rig.settle()
        #expect(try await eventually { rig.firstPicturePTS != nil })
        let first = try #require(rig.firstPicturePTS)
        let start = TimeShiftStream.pts(at: TimeShiftStream.lastPicture(of: 300) - held)
        #expect(abs(first - start) <= 2 * Self.pictureTicks)
    }

    /// A file that fits the ring: on demand, its whole length once read, seekable anywhere.
    @Test func aFileIsOnDemandWithItsDuration() async throws {
        let data = try #require(await TimeShiftStream.ten())
        let rig = SeekRig(source: FiniteSource(data: data, chunk: 188 * 64))
        rig.pipeline.start()
        defer { rig.pipeline.stop() }
        #expect(try await eventually { rig.timeline.map { $0.range.upperBound > 9 } == true })
        let timeline = try #require(rig.timeline)
        #expect(!timeline.isLive)
        #expect(timeline.range.lowerBound == 0)
        #expect(abs(timeline.range.upperBound - TimeShiftStream.lastPicture(of: 300)) < 0.001)
        rig.pipeline.seek(toTime: 8.5)
        try await Self.expectLanding(rig, at: 8.5)
    }

    /// A file four times the ring: its length is estimated, and a seek beyond the ring reopens it near the target
    /// and lands on the target.
    @Test func aFileLargerThanTheRingReopensToSeek() async throws {
        let data = try #require(await TimeShiftStream.ten())
        let opens = Counter()
        let rig = SeekRig(source: ReopenableSource(data: data, opens: opens), ringBytes: data.count / 4)
        rig.pipeline.start()
        defer { rig.pipeline.stop() }
        #expect(try await eventually { rig.timeline != nil })
        let timeline = try #require(rig.timeline)
        #expect(!timeline.isLive)
        #expect(timeline.range.upperBound > 7 && timeline.range.upperBound < 13)
        rig.pipeline.seek(toTime: 8)
        try await Self.expectLanding(rig, at: 8)
        #expect(opens.value >= 2)
        // The reopened stream read to its end: the duration is exact now.
        #expect(try await eventually {
            rig.timeline.map { abs($0.range.upperBound - TimeShiftStream.lastPicture(of: 300)) < 0.001 } == true
        })
        rig.pipeline.seek(toTime: 1)
        try await Self.expectLanding(rig, at: 1)
        #expect(rig.log.failure == nil)
    }

    /// A file four times the ring knows its exact length long before its end is read: its tail is read once, on its
    /// own connection, for the last picture's PTS. The estimate from the byte rate is only what shows meanwhile.
    @Test func aFileLargerThanTheRingLearnsItsLengthFromItsTail() async throws {
        let data = try #require(await TimeShiftStream.ten())
        let opens = Counter()
        let rig = SeekRig(source: ReopenableSource(data: data, opens: opens), ringBytes: data.count / 4)
        rig.pipeline.start()
        defer { rig.pipeline.stop() }
        #expect(try await eventually {
            rig.timeline.map { abs($0.range.upperBound - TimeShiftStream.lastPicture(of: 300)) < 0.001 } == true
        })
        // The tail was its own connection; playback is still near the start.
        #expect(opens.value >= 2)
        #expect((rig.timeline?.position ?? .infinity) < 5)
        #expect(rig.log.failure == nil)
    }

    /// A paused engine seeks without playing; an engine whose file ended plays on from the new point.
    @Test func theEngineKeepsItsPauseAndRestartsAnEndedFile() async throws {
        let data = try #require(await TimeShiftStream.three())
        let engine = TransportStreamEngine(makeSource: { FiniteSource(data: data, chunk: 188 * 64) },
                                           timeShift: TimeShiftConfiguration(storage: .memory, capacityBytes: 4 << 20))
        engine.start()
        defer { engine.stop() }
        #expect(try await eventually { engine.timeline() != nil && engine.state == .playing })
        engine.pause()
        engine.seek(toPosition: 2)
        #expect(engine.state == .paused)
        #expect(engine.timeline().map { abs($0.position - 2) < 0.01 } == true)
        try await Task.sleep(for: .milliseconds(600))
        #expect(engine.state == .paused)
        let paused = try #require(engine.timeline())
        #expect(abs(paused.position - 2) < 0.05, "paused at \(paused.position)")
        engine.resume()
        #expect(try await eventually { engine.state == .ended })
        #expect(engine.timeline() != nil)
        engine.skip(by: -2)
        #expect(engine.state == .playing)
        #expect(try await eventually { engine.state == .ended })
    }
}
#endif
