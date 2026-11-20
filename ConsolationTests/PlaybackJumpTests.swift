//
//  PlaybackJumpTests.swift
//  ConsolationTests
//
//  Apple TV's left and right jumps: 10 s steps clamped to what the stream can reach, nothing forward at a live
//  stream's live edge, and a run that adds up in the pill.
//

import Foundation
import PlaybackKit
import Testing
@testable import Consolation

struct PlaybackJumpTests {
    private let now = ContinuousClock.now

    private func onDemand(at position: Double) -> PlaybackTimeline {
        PlaybackTimeline(range: 0...600, position: position, isLive: false)
    }

    @Test func aRunAddsUpFromWhereTheLastJumpWent() throws {
        let first = try #require(PlaybackJump.next(after: nil, by: 10, in: onDemand(at: 100), isPlaying: false,
                                                   now: now))
        #expect(first.target == 110)
        #expect(first.label == "+10s")
        // The engine still reports the old position: the run continues from the last target.
        let second = try #require(PlaybackJump.next(after: first, by: 10, in: onDemand(at: 100), isPlaying: false,
                                                    now: now))
        #expect(second.target == 120)
        #expect(second.label == "+20s")
        let back = try #require(PlaybackJump.next(after: second, by: -30, in: onDemand(at: 100), isPlaying: false,
                                                  now: now))
        #expect(back.target == 90)
        #expect(back.label == "−10s")
    }

    @Test func playingTimeCountsTowardTheNextJump() throws {
        let first = try #require(PlaybackJump.next(after: nil, by: 10, in: onDemand(at: 100), isPlaying: true,
                                                   now: now))
        let second = try #require(PlaybackJump.next(after: first, by: 10, in: onDemand(at: 100), isPlaying: true,
                                                    now: now + .seconds(2)))
        #expect(second.target == 122)
        #expect(second.label == "+20s")
    }

    @Test func jumpsAreClampedAndStopAtTheEnds() throws {
        let nearEnd = try #require(PlaybackJump.next(after: nil, by: 10, in: onDemand(at: 595), isPlaying: false,
                                                     now: now))
        #expect(nearEnd.target == 600)
        #expect(nearEnd.label == "+5s")
        #expect(PlaybackJump.next(after: nil, by: 10, in: onDemand(at: 600), isPlaying: false, now: now) == nil)
        #expect(PlaybackJump.next(after: nil, by: -10, in: onDemand(at: 0), isPlaying: false, now: now) == nil)
    }

    @Test func liveStreamsDontJumpAheadAtTheLiveEdge() {
        let live = PlaybackTimeline(range: 0...300, position: 298, isLive: true)
        #expect(PlaybackJump.next(after: nil, by: 10, in: live, isPlaying: true, now: now) == nil)
        #expect(PlaybackJump.next(after: nil, by: -10, in: live, isPlaying: true, now: now)?.target == 288)
    }

    @Test func labelsShowMinutesPastAMinute() {
        func label(_ total: Double) -> String {
            PlaybackJump(total: total, target: 0, time: now).label
        }
        #expect(label(30) == "+30s")
        #expect(label(-60) == "−1m")
        #expect(label(90) == "+1m 30s")
        #expect(label(0) == "0s")
    }
}
