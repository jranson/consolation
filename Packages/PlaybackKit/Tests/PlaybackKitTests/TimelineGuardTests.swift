//
//  TimelineGuardTests.swift
//  PlaybackKitTests
//

@testable import PlaybackKit
import Testing

struct TimelineGuardTests {
    private static let video: UInt16 = 0x31
    private static let audio: UInt16 = 0x34
    private static let second: Int64 = 90_000

    @Test func acceptsASteadyStreamWithReorderedPictures() {
        var timeline = TimelineGuard()
        // Decode order I P B B: presentation times step back by a frame or two.
        for pts: Int64 in [3_003, 12_012, 6_006, 9_009, 21_021, 15_015, 18_018] {
            #expect(timeline.admit(pid: Self.video, pts: pts) == .accept)
        }
        #expect(timeline.admit(pid: Self.video, pts: nil) == .accept)
    }

    @Test func restartsOnABackwardJumpAndDropsTheLaggingStreamUntilItJumps() {
        var timeline = TimelineGuard()
        let start = 100 * Self.second
        #expect(timeline.admit(pid: Self.video, pts: start) == .accept)
        #expect(timeline.admit(pid: Self.audio, pts: start - Self.second) == .accept)
        // The video jumps back 15 s first; audio from the old timeline is still arriving.
        #expect(timeline.admit(pid: Self.video, pts: start - 15 * Self.second) == .restart)
        #expect(timeline.admit(pid: Self.audio, pts: start - Self.second / 2) == .drop)
        #expect(timeline.admit(pid: Self.audio, pts: nil) == .drop)
        #expect(timeline.admit(pid: Self.video, pts: start - 15 * Self.second + 3_003) == .accept)
        // Then the audio jumps too and rejoins.
        #expect(timeline.admit(pid: Self.audio, pts: start - 16 * Self.second) == .rejoin)
        #expect(timeline.admit(pid: Self.audio, pts: start - 16 * Self.second + 2_880) == .accept)
    }

    @Test func restartsOnALargeForwardJumpButNotOnAShortGap() {
        var timeline = TimelineGuard()
        #expect(timeline.admit(pid: Self.video, pts: 0) == .accept)
        #expect(timeline.admit(pid: Self.video, pts: 2 * Self.second) == .accept)
        #expect(timeline.admit(pid: Self.video, pts: 3_600 * Self.second) == .restart)
    }

    @Test func takesALaggingStreamAsItIsAfterTheLagLimit() {
        var timeline = TimelineGuard()
        #expect(timeline.admit(pid: Self.video, pts: 50 * Self.second) == .accept)
        #expect(timeline.admit(pid: Self.audio, pts: 50 * Self.second) == .accept)
        #expect(timeline.admit(pid: Self.video, pts: 10 * Self.second) == .restart)
        var pts = 50 * Self.second
        while pts <= 50 * Self.second + TimelineGuard.lagLimit {
            #expect(timeline.admit(pid: Self.audio, pts: pts) == .drop)
            pts += Self.second / 2
        }
        #expect(timeline.admit(pid: Self.audio, pts: pts) == .rejoin)
    }
}
