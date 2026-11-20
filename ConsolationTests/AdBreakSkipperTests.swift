//
//  AdBreakSkipperTests.swift
//  ConsolationTests
//
//  Skip Commercials is offered while playback is inside a break, Back dismisses it for the rest of that break, and
//  leaving the break forgets the dismissal.
//

import MediaSourceKit
import Testing
@testable import Consolation

@MainActor
struct AdBreakSkipperTests {
    private let first = AdBreak(start: 60, end: 120)
    private let second = AdBreak(start: 300, end: 360)

    private func skipper() -> AdBreakSkipper {
        let skipper = AdBreakSkipper { _ in .none }
        skipper.breaks = [first, second]
        return skipper
    }

    @Test func theBreakPlayingIsOffered() {
        let skipper = skipper()
        skipper.offer(at: 30)
        #expect(skipper.current == nil)
        skipper.offer(at: 61)
        #expect(skipper.current == first)
        skipper.offer(at: 305)
        #expect(skipper.current == second)
        skipper.offer(at: nil)
        #expect(skipper.current == nil)
    }

    @Test func backDismissesTheRestOfThatBreakOnly() {
        let skipper = skipper()
        skipper.offer(at: 61)
        skipper.dismiss()
        #expect(skipper.current == nil)
        skipper.offer(at: 90)
        #expect(skipper.current == nil, "still dismissed later in the same break")
        skipper.offer(at: 130)
        skipper.offer(at: 70)
        #expect(skipper.current == first, "seeking back into it after leaving offers it again")
        skipper.dismiss()
        skipper.offer(at: 301)
        #expect(skipper.current == second, "the next break is offered")
    }
}
